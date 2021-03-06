package MediaWords::Crawler::Fetcher;
use Modern::Perl "2013";
use MediaWords::CommonLibs;

use strict;

use DateTime;
use LWP::UserAgent;

use MediaWords::DB;
use DBIx::Simple::MediaWords;
use MediaWords::Util::Config;

sub new
{
    my ( $class, $engine ) = @_;

    my $self = {};
    bless( $self, $class );

    $self->engine( $engine );

    return $self;
}

# alarabiya uses an interstitial that requires javascript.  if the download url 
# matches alarabiya and returns the 'requires JavaScript' page, manually parse
# out the necessary cookie and add it to the $ua so that the request will work
sub fix_alarabiya_response
{
    my ( $download, $ua, $response ) = @_;
    
    return $response unless ( $download->{ url } =~ /alarabiya/ );
    
    if ( $response->content !~ /This site requires JavaScript and Cookies to be enabled/ )
    {
        return $response;
    }
    
    if ( $response->content =~ /setCookie\('([^']+)', '([^']+)'/ )
    {
        my $response = $ua->get( $download->{ url }, Cookie => "$1=$2" );
        
        return $response;
    }
    else
    {
        warn( "Unable to parse cookie from alarabiya: " . $response->content );
        return $response;
    }
}



sub do_fetch
{
    my ( $download, $dbs ) = @_;

    $download->{ download_time } = DateTime->now->datetime;
    $download->{ state }         = 'fetching';

    $dbs->update_by_id( "downloads", $download->{ downloads_id }, $download );

    my $ua     = LWP::UserAgent->new();
    my $config = MediaWords::Util::Config::get_config;


    $ua->from( $config->{ mediawords }->{ owner } );
    $ua->agent( $config->{ mediawords }->{ user_agent } );
    $ua->cookie_jar( {} );

    $ua->timeout( 20 );
    $ua->max_size( 1024 * 1024 );
    $ua->max_redirect( 15 );
    $ua->env_proxy;

    my $response = $ua->get( $download->{ url } );

    $response = fix_alarabiya_response( $download, $ua, $response );
    
    return $response;
}

sub fetch_download
{
    my ( $self, $download ) = @_;

    my $dbs = $self->engine->dbs;

    return do_fetch( $download, $dbs );
}

# calling engine
sub engine
{
    if ( $_[ 1 ] )
    {
        $_[ 0 ]->{ engine } = $_[ 1 ];
    }

    return $_[ 0 ]->{ engine };
}

1;
