#!/usr/bin/env perl

use strict;
use warnings;

BEGIN
{
    use FindBin;
    use lib "$FindBin::Bin/../lib";
}

use MediaWords::DB;
use Modern::Perl "2012";
use MediaWords::CommonLibs;

use MediaWords::DBI::DownloadTexts;
use MediaWords::DBI::Stories;
use MediaWords::StoryVectors;
use MediaWords::Util::MC_Fork;

use XML::LibXML;
use MIME::Base64;
use Encode;
use Data::Dumper;
use MediaWords::Crawler::Handler;
use Carp;
use Try::Tiny;
use Text::Trim;

sub hash_from_element
{
    my ( $element, $excluded_keys ) = @_;

    #say "start hash_from_element ";
    #say Dumper( $element );

    #say 'starting hash_from_element for ' . $element->nodeName();

    my @childNodes = $element->childNodes();

    my $node_types = [ map { $_->nodeType } @childNodes ];

    my $ret;

    $ret = { map { $_->nodeName() => $_->textContent() } @childNodes };

    ## Fix for extra white space on forrest.
    foreach my $key ( keys %{ $ret } )
    {
	$ret->{ $key } = trim( $ret->{ $key } );
    }

    #say Dumper ( $ret );

    #say 'hash_from_element returning ' . Dumper ( $ret );

    if ( $excluded_keys )
    {
        foreach my $excluded_key ( @$excluded_keys )
        {
            delete( $ret->{ $excluded_key } );
        }
    }

     foreach my $key ( sort keys %{ $ret } )
     {
             if ( !defined( $ret->{ $key } ) ||  $ret->{ $key } eq '' )
             {
                 undef($ret->{ $key });
                 next;
             }
     }

    return $ret;
}

sub import_downloads
{
    my ( $xml_file_name ) = @_;

    say "processing file $xml_file_name";

    open my $fh, $xml_file_name || die "Error opening file:$xml_file_name $@";

    my $parser = XML::LibXML->new;

    #my $doc = $parser->parse_fh( $fh, { no_blanks => 1 } );
    my $doc = XML::LibXML->load_xml(
        {
            IO        => $fh,
            no_blanks => 1,
        }
    );

    my $root = $doc->documentElement() || die;

    my $db = MediaWords::DB::connect_to_db;

    my $downloads_processed = 0;

    my @root_child_nodes =  $root->childNodes();

    my $feed_downloads_processed = 0;

    foreach my $child_node ( @root_child_nodes )
    {
        $feed_downloads_processed++;

        say "Processing $xml_file_name: download $feed_downloads_processed out of ". scalar ( @root_child_nodes ) .;

        #say STDERR "child_node: " . $child_node->nodeName();

        my $download = hash_from_element( $child_node, [ qw ( child_stories ) ] );

        #say STDERR $root->toString( 2);
        #say STDERR Dumper( $child_node );

        #say STDERR $child_node->toString( 2 );
        #say STDERR Dumper( $download );

        my $old_downloads_id = $download->{ downloads_id };
        delete( $download->{ downloads_id } );

        my $decoded_content = $download->{ encoded_download_content_base_64 }
          && decode_base64( $download->{ encoded_download_content_base_64 } );
        delete( $download->{ encoded_download_content_base_64 } );

        #say STDERR Dumper( $download );

        next if ( '(redundant feed)' eq $decoded_content );    # The download contains no content so don't add it.

        my @child_stories_list = $child_node->getElementsByTagName( "child_stories" );

        die unless ( scalar( @child_stories_list ) == 1 );

        my $child_stories_element = $child_stories_list[ 0 ];

        # say "Dumping child stories list";
        # say Dumper ( [ @child_stories_list ] );
        # say "Dumping child stories element";
        # say Dumper ( $child_stories_element );

        my $story_elements = [ $child_stories_element->getElementsByTagName( "story" ) ];

        my $new_stories = [];

        foreach my $story_element ( @{ $story_elements } )
        {

            #say Dumper ( $story_elements );
            my $story = hash_from_element( $story_element, [ qw ( story_downloads ) ] );

            if ( MediaWords::DBI::Stories::is_new( $db, $story ) )
            {
                #say 'new story:';
                #say Dumper( $story );

                push @{ $new_stories }, $story_element;
            }
        }

        #say 'got new stories';
        #say Dumper ( $new_stories );

	if ( scalar( @ { $new_stories } ) == 0 )
	{
	    say "No new stories for download $feed_downloads_processed out of ". scalar ( @root_child_nodes ) . " in $xml_file_name";
	    next;
	}

	say "Creating new downloads";

        my $db_download = $db->create( 'downloads', $download );

        MediaWords::DBI::Downloads::store_content( $db, $db_download, \$decoded_content );

        foreach my $story_element ( @$new_stories )
        {

            # dump stories and downloads.

            my $story_hash;

            try
            {
                $story_hash = hash_from_element( $story_element, [ qw ( story_downloads ) ] );
                confess 'null story_hash ' unless $story_hash;
            }
            catch
            {
                confess STDERR "error in hash_from_element: $_";
            };

            confess 'null story_hash ' unless $story_hash;

            my $old_stories_id = $story_hash->{ stories_id };

            delete( $story_hash->{ stories_id } );

            my $db_story =
              MediaWords::Crawler::FeedHandler::_add_story_using_parent_download( $db, $story_hash, $db_download );
            my @story_downloads_list = $story_element->getElementsByTagName( "story_downloads" );

            die unless ( scalar( @story_downloads_list ) == 1 );

            my $story_downloads_list_element = $story_downloads_list[ 0 ];

            my @story_downloads = $story_downloads_list_element->getElementsByTagName( "download" );

            my $parent = $db_download;
            foreach my $story_download ( @story_downloads )
            {
                my $download_hash = hash_from_element( $story_download, [ qw ( child_stories ) ] );

                if ( $download_hash->{ state } ne 'success' )
                {
                    $download_hash->{ state } = 'pending';
                }

                $download_hash->{ parent }     = $parent->{ downloads_id };
                $download_hash->{ stories_id } = $db_story->{ stories_id };
                $download_hash->{ extracted }  = 'f';
                $download_hash->{ path }       = '';

		my $story_download_decoded_content = $download_hash->{ encoded_download_content_base_64 }
                  && decode_base64( $download_hash->{ encoded_download_content_base_64 } );
		delete( $download_hash->{ encoded_download_content_base_64 } );

		if ( !defined ( $download_hash->{ host } ) )
		{
		   $download_hash->{ host } = '';
		}

                my $db_story_download = $db->create( 'downloads', $download_hash );

		if ( $db_story_download->{ state } eq 'sucess' )
		{
		   MediaWords::DBI::Downloads::store_content( $db, $db_story_download, \$story_download_decoded_content );
		 }

                $parent = $db_story_download;
            }
        }
    }
}

# fork of $num_processes
sub main
{
    my $xml_file_name = shift( @ARGV );

    die "Must specify file name" unless $xml_file_name;

    binmode STDOUT, ":utf8";
    binmode STDERR, ":utf8";

    import_downloads( $xml_file_name );
}

main();
