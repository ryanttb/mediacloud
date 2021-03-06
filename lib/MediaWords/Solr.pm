package MediaWords::Solr;

use strict;

use Modern::Perl "2013";
use MediaWords::CommonLibs;

# functions for searching the solr server

use JSON;
use List::Util;
use Time::HiRes qw(gettimeofday tv_interval);

use MediaWords::DBI::Stories;
use MediaWords::Languages::Language;
use MediaWords::Util::Config;
use MediaWords::Util::Web;
use List::MoreUtils qw ( uniq );

my $_last_num_found;

# get a solr select url from config.  if there is more than one url
# in the config, randomly choose one from the list.
sub get_solr_select_url
{
    my $urls = MediaWords::Util::Config::get_config->{ mediawords }->{ solr_select_url };

    return $urls unless ( ref( $urls ) );

    return $urls->[ int( rand( scalar( @{ $urls } ) ) ) ];
}

# get the numFound from the last solr query run
sub get_last_num_found
{
    return $_last_num_found;
}

sub _set_last_num_found
{
    my ( $res ) = @_;

    if ( defined( $res->{ response }->{ num_found } ) )
    {
        $_last_num_found = $res->{ response }->{ numFound };
    }
    elsif ( $res->{ grouped } )
    {
        my $group_key = ( keys( %{ $res->{ grouped } } ) )[ 0 ];

        $_last_num_found = $res->{ grouped }->{ $group_key }->{ matches };
    }
    else
    {
        $_last_num_found = undef;
    }

    print STDERR ( $_last_num_found ? $_last_num_found : 'undef' ) . " matches found.\n" if ( $ENV{ MC_SOLR_TRACE } );

}

# execute a query on the solr server using the given params.
# return the raw encoded json from solr.  return a maximum of
# 1 million sentences.
sub query_encoded_json
{
    my ( $params ) = @_;

    $params->{ wt } = 'json';
    $params->{ rows } //= 1000;
    $params->{ df }   //= 'sentence';

    $params->{ rows } = List::Util::min( $params->{ rows }, 1000000 );

    my $url = get_solr_select_url();

    my $ua = MediaWords::Util::Web::UserAgent;

    $ua->timeout( 300 );
    $ua->max_size( undef );

    print STDERR "executing solr query on $url ...\n" if ( $ENV{ MC_SOLR_TRACE } );
    print STDERR Dumper( $params ) if ( $ENV{ MC_SOLR_TRACE } );

    my $t0 = [ gettimeofday ];

    my $res = $ua->post( $url, $params );

    print STDERR "query returned in " . tv_interval( $t0, [ gettimeofday ] ) . "s.\n" if ( $ENV{ MC_SOLR_TRACE } );

    die( "Error fetching solr response: " . $res->as_string ) unless ( $res->is_success );

    return $res->content;
}

# execute a query on the solr server using the given params.
# return a hash generated from the json results
sub query
{
    my ( $params ) = @_;

    my $json = query_encoded_json( $params );

    my $data;
    eval { $data = decode_json( $json ) };
    if ( $@ )
    {
        die( "Error parsing solr json: $@\n$json" );
    }

    if ( $data->{ error } )
    {
        die( "Error received from solr: '$json'" );
    }

    _set_last_num_found( $data );

    return $data;
}

# return all of the story ids that match the solr query
sub search_for_stories_ids
{
    my ( $params ) = @_;

    my $p = { %{ $params } };

    $p->{ fl }            = 'stories_id';
    $p->{ group }         = 'true';
    $p->{ 'group.field' } = 'stories_id';

    my $response = query( $p );

    my $groups = $response->{ grouped }->{ stories_id }->{ groups };
    my $stories_ids = [ map { $_->{ doclist }->{ docs }->[ 0 ]->{ stories_id } } @{ $groups } ];

    return $stories_ids;
}

sub number_of_matching_documents
{
    my ( $params ) = @_;

    $params = { %{ $params } };

    undef $params->{ sort };

    $params->{ rows } = 0;

    my $response = query( $params )->{ response };

    #say STDERR Dumper( $response );

    #say STDERR $response->{ numFound };

    return $response->{ numFound };
}

# return the first $num_stories processed_stories_id that match the given query,
# sorted by processed_stories_id and with processed_stories_id greater than $last_ps_id.
sub search_for_processed_stories_ids ($$$$)
{
    my ( $q, $fq, $last_ps_id, $num_stories ) = @_;

    return [] unless ( $num_stories );

    my $params;

    $params->{ q }             = $q;
    $params->{ fq }            = $fq;
    $params->{ fl }            = 'processed_stories_id';
    $params->{ sort }          = 'processed_stories_id asc';
    $params->{ rows }          = $num_stories;
    $params->{ group }         = 'true';
    $params->{ 'group.field' } = 'stories_id';

    if ( $last_ps_id )
    {
        my $min_ps_id = $last_ps_id + 1;
        $params->{ fq } = [ @{ $params->{ fq } }, "processed_stories_id:[$min_ps_id TO *]" ];
    }

    my $response = query( $params );

    my $groups = $response->{ grouped }->{ stories_id }->{ groups };
    my $ps_ids = [ map { $_->{ doclist }->{ docs }->[ 0 ]->{ processed_stories_id } } @{ $groups } ];

    return $ps_ids;
}

# return stories.* for all stories matching the give solr query
sub search_for_stories
{
    my ( $db, $params ) = @_;

    my $stories_ids = search_for_stories_ids( $params );

    my $stories = [ map { { stories_id => $_ } } @{ $stories_ids } ];

    MediaWords::DBI::Stories::attach_story_meta_data_to_stories( $db, $stories );

    $stories = [ grep { $_->{ url } } @{ $stories } ];

    return $stories;
}

# return all of the stories that match the solr query.  attach a list of matching sentences in story order
# to each story as well as the stories.* fields from postgres.

# limit to first $num_sampled stories $num_sampled is specified.  return first rows returned by solr
# if $random is not true (and only an estimate of the total number of matching stories ).  fetch all results
# from solr and return a random sample of those rows if $random is true (and an exact count of the number of
# matching stories
#
# returns the (optionally sampled) stories and the total number of matching stories.
sub search_for_stories_with_sentences
{
    my ( $db, $params, $num_sampled, $random ) = @_;

    $params = { %{ $params } };

    $params->{ fl } = 'stories_id,sentence,story_sentences_id';

    $params->{ rows } = ( $num_sampled ) ? ( $num_sampled * 2 ) : 1000000;

    $params->{ sort } = 'random_1 asc' if ( $random );

    my $response = query( $params );

    my $stories_lookup = {};
    for my $doc ( @{ $response->{ response }->{ docs } } )
    {
        $stories_lookup->{ $doc->{ stories_id } } ||= [];
        push( @{ $stories_lookup->{ $doc->{ stories_id } } }, $doc );
    }

    my $stories = [];
    while ( my ( $stories_id, $sentences ) = each( %{ $stories_lookup } ) )
    {
        my $ordered_sentences = [ sort { $a->{ story_sentences_id } <=> $b->{ story_sentences_id } } @{ $sentences } ];
        push( @{ $stories }, { stories_id => $stories_id, sentences => $ordered_sentences } );
    }

    my $num_stories = @{ $stories };
    if ( $num_sampled && ( $num_stories > $num_sampled ) )
    {
        map { $_->{ _s } = Digest::MD5::md5_hex( $_->{ stories_id } ) } @{ $stories };
        $stories = [ ( sort { $a->{ _s } cmp $b->{ _s } } @{ $stories } )[ 0 .. ( $num_sampled - 1 ) ] ];
        $num_stories = int( $response->{ response }->{ numFound } / 2 );
    }

    MediaWords::DBI::Stories::attach_story_meta_data_to_stories( $db, $stories );

    return ( $stories, $num_stories );
}

# execute the query and return only the number of documents found
sub get_num_found
{
    my ( $params ) = @_;

    $params = { %{ $params } };
    $params->{ rows } = 0;

    my $res = query( $params );

    return $res->{ response }->{ numFound };
}

# fetch word counts from a separate server
sub _get_remote_word_counts
{
    my ( $q, $fq, $languages ) = @_;

    my $url = MediaWords::Util::Config::get_config->{ mediawords }->{ solr_wc_url };
    my $key = MediaWords::Util::Config::get_config->{ mediawords }->{ solr_wc_key };
    return undef unless ( $url && $key );

    my $ua = MediaWords::Util::Web::UserAgent();

    $ua->timeout( 600 );
    $ua->max_size( undef );

    my $l = join( " ", @{ $languages } );

    my $uri = URI->new( $url );
    $uri->query_form( { q => $q, fq => $fq, l => $l, key => $key, nr => 1 } );

    my $res = $ua->get( $uri, Accept => 'application/json' );

    die( "error retrieving words from solr: " . $res->as_string ) unless ( $res->is_success );

    my $words = from_json( $res->content, { utf8 => 1 } );

    die( "Unable to parse json" ) unless ( $words && ( ref( $words ) eq 'ARRAY' ) );

    return $words;
}

# return CHI cache for word counts
sub _get_word_count_cache
{
    my $mediacloud_data_dir = MediaWords::Util::Config::get_config->{ mediawords }->{ data_dir };

    return CHI->new(
        driver           => 'File',
        expires_in       => '1 day',
        expires_variance => '0.1',
        root_dir         => "${ mediacloud_data_dir }/cache/word_counts",
        cache_size       => '1g'
    );
}

# get a cached value for the given word count
sub _get_cached_word_counts
{
    my ( $q, $fq, $languages ) = @_;

    my $cache = _get_word_count_cache();

    my $key = Dumper( $q, $fq, $languages );
    return $cache->get( $key );
}

# set a cached value for the given word count
sub _set_cached_word_counts
{
    my ( $q, $fq, $languages, $value ) = @_;

    my $cache = _get_word_count_cache();

    my $key = Dumper( $q, $fq, $languages );
    return $cache->set( $key, $value );
}

# get sorted list of most common words in sentences matching a solr query.  exclude stop words from the
# long_stop_word list.  assumes english stemming and stopwording for now.
sub count_words
{
    my ( $q, $fq, $languages, $no_remote ) = @_;

    my $words;
    $words = _get_remote_word_counts( $q, $fq, $languages ) unless ( $no_remote );

    $words ||= _get_cached_word_counts( $q, $fq, $languages );

    if ( !$words )
    {
        $words = MediaWords::Solr::WordCounts::words_from_solr_server( $q, $fq, $languages );
        _set_cached_word_counts( $q, $fq, $languages, $words );
    }

    return $words;
}

1;
