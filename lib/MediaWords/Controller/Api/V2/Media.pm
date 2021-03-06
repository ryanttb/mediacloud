package MediaWords::Controller::Api::V2::Media;
use Modern::Perl "2013";
use MediaWords::CommonLibs;

use MediaWords::DBI::StorySubsets;
use MediaWords::Controller::Api::V2::MC_Action_REST;
use strict;
use warnings;
use base 'Catalyst::Controller';
use JSON;
use List::Util qw(first max maxstr min minstr reduce shuffle sum);
use Moose;
use namespace::autoclean;
use List::Compare;
use Carp;

=head1 NAME

MediaWords::Controller::Media - Catalyst Controller

=head1 DESCRIPTION

Catalyst Controller.

=head1 METHODS

=cut

=head2 index 

=cut

BEGIN { extends 'MediaWords::Controller::Api::V2::MC_REST_SimpleObject' }

use constant ROWS_PER_PAGE => 20;

use MediaWords::Tagger;

sub get_table_name
{
    return "media";
}

sub has_nested_data
{
    return 1;
}

sub _add_nested_data
{

    my ( $self, $db, $media ) = @_;

    foreach my $media_source ( @{ $media } )
    {
        # say STDERR "adding media_source tags ";
        my $media_source_tags = $db->query(
"select tags.tags_id, tags.tag, tag_sets.tag_sets_id, tag_sets.name as tag_set from media_tags_map natural join tags natural join tag_sets where media_id = ? ORDER by tags_id",
            $media_source->{ media_id }
        )->hashes;
        $media_source->{ media_source_tags } = $media_source_tags;
    }

    foreach my $media_source ( @{ $media } )
    {
        # say STDERR "adding media_sets ";
        my $media_source_tags = $db->query(
"select media_sets.media_sets_id, media_sets.name, media_sets.description, media_sets.set_type from media_sets_media_map natural join media_sets where media_id = ? ORDER by media_sets_id",
            $media_source->{ media_id }
        )->hashes;
        $media_source->{ media_sets } = $media_source_tags;
    }

    return $media;

}

sub default_output_fields
{
    return [ qw ( name url media_id ) ];
}

=head1 AUTHOR

David Larochelle

=head1 LICENSE

This library is free software, you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;
