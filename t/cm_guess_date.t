use strict;
use warnings;

use Test::NoWarnings;
use Test::More tests => 41 + 1;
use Test::Deep;

use utf8;

use Modern::Perl "2013";
use MediaWords::CommonLibs;

# Integer constants (in case Date::Parse::str2time fails)
use constant _TIMESTAMP_12_00_GMT => 1326801600;    # Tue, 17 Jan 2012 12:00:00 GMT (UTC); for dates without time / timezone
use constant _TIMESTAMP_12_00_EST => 1326819600;    # Tue, 17 Jan 2012 12:00:00 EST (-05:00)

BEGIN { use_ok 'MediaWords::CM::GuessDate' }
BEGIN { use_ok 'MediaWords::CM::GuessDate::Result' }
BEGIN { use_ok 'Date::Parse' }
BEGIN { use_ok 'LWP::Simple' }
BEGIN { use_ok 'LWP::Protocol::https' }

my $db = MediaWords::DB::connect_to_db();

# Returns URL dating result
sub _gr($;$$)
{
    my ( $html, $story_url, $story_publish_date ) = @_;
    $story_url          ||= 'http://www.example.com/story.html';
    $story_publish_date ||= 'unknown';
    my $story = { url => $story_url, publish_date => $story_publish_date };

    return MediaWords::CM::GuessDate::guess_date( $db, $story, $html );
}

# Returns timestamp of the page or undef
sub _gt($;$$)
{
    my ( $html, $story_url, $story_publish_date ) = @_;

    my $result = _gr( $html, $story_url, $story_publish_date );
    if ( $result->{ result } eq MediaWords::CM::GuessDate::Result::FOUND )
    {
        return $result->{ timestamp };
    }
    else
    {
        return undef;
    }
}

# Returns dating result of the page; also fetches the URL
sub _gr_url($;$)
{
    my ( $story_url, $story_publish_date ) = @_;

    my $html = '';
    unless ( $story_url =~ /example\.(com|net|org)$/gi )
    {

        # 404 Not Found pages will be empty
        $html = get( $story_url ) || '';
    }

    return _gr( $html, $story_url, $story_publish_date );
}

# Returns timestamp of the page or undef; also fetches the URL
sub _gt_url($;$)
{
    my ( $story_url, $story_publish_date ) = @_;

    my $result = _gr_url( $story_url, $story_publish_date );

    # say STDERR Dumper($result);
    if ( $result->{ result } eq MediaWords::CM::GuessDate::Result::FOUND )
    {
        return $result->{ timestamp };
    }
    else
    {
        return undef;
    }
}

# Shorthand for timestamp_from_html()
sub _ts_from_html($)
{
    my $html = shift;

    return MediaWords::CM::GuessDate::timestamp_from_html( $html );
}

# Shortcut for making UNIX timestamps out of RFC 822 dates
sub _ts($)
{
    my $date = shift;
    return Date::Parse::str2time( $date );
}

sub test_dates
{
    is( _gt( '<meta name="DC.date.issued" content="2012-01-17T12:00:00-05:00" />' ),
        _TIMESTAMP_12_00_EST, 'guess_by_dc_date_issued' );
    is(
        _gt(
            '<li property="dc:date dc:created" ' . 'content="2012-01-17T12:00:00-05:00" ' .
              'datatype="xsd:dateTime" class="created">' . 'January 17, 2012</li>'
        ),
        _TIMESTAMP_12_00_EST,
        'guess_by_dc_created'
    );
    is( _gt( '<meta name="item-publish-date" content="Tue, 17 Jan 2012 12:00:00 EST" />' ),
        _TIMESTAMP_12_00_EST, 'guess_by_meta_publish_date' );

    is( _gt( '<meta property="article:published_time" content="2012-01-17T12:00:00-05:00" />' ),
        _TIMESTAMP_12_00_EST, 'guess_by_og_article_published_time' );

    is( _gt( '<meta name="sailthru.date" content="Tue, 17 Jan 2012 12:00:00 -0500">' ),
        _TIMESTAMP_12_00_EST, 'guess_by_sailthru_date' );

    # Assume that the timezone is GMT
    is( _gt( '<p class="storydate">Tue, Jan 17th 2012</p>' ), _TIMESTAMP_12_00_GMT, 'guess_by_storydate' );

    is( _gt( '<span class="date" data-time="1326819600">Jan 17, 2012 12:00 pm EST</span>' ),
        _TIMESTAMP_12_00_EST, 'guess_by_datatime' );

    # FIXME _guess_by_datetime_pubdate() ignores contents, uses @datetime instead;
    # and @datetime assumes that the timezone is GMT.
    is( _gt( '<time datetime="2012-01-17" pubdate>Jan 17, 2012 12:00 pm EST</time>' ),
        _TIMESTAMP_12_00_GMT, 'guess_by_datetime_pubdate' );

    is( _gt( '<p>Hello!</p>', 'http://www.example.com/news/2012/01/17/hello.html' ), _TIMESTAMP_12_00_GMT, 'guess_by_url' );

    # Expected to prefer the date in text, fallback to the date in URL
    is( _gt( 'Jan 17th, 2012, 05:00 AM GMT', 'http://www.example.com/news/2012/01/17/hello.html' ),
        _TIMESTAMP_12_00_GMT, 'guess_by_url_and_date_text in URL' );
    is( _gt( 'Jan 17th, 2012, 12:00 PM EST', 'http://www.example.com/news/2012/01/17/hello.html' ),
        _TIMESTAMP_12_00_EST, 'guess_by_url_and_date_text in text and URL' );

    is( _gt( '<p class="date">Jan 17, 2012</p>' ), _TIMESTAMP_12_00_GMT, 'guess_by_class_date' );
    is( _gt( '<p>foo bar</p><p class="dateline>published on Jan 17th, 2012, 12:00 PM EST' ),
        _TIMESTAMP_12_00_EST, 'guess_by_date_text' );
    is( _gt( '<p>Hey!</p>', undef, '2012-01-17T12:00:00-05:00' ), _TIMESTAMP_12_00_EST, 'guess_by_existing_story_date' );
    is( _gt( '<meta name="pubdate" content="2012-01-17 12:00:00" />' ), _TIMESTAMP_12_00_GMT, 'guess_by_meta_pubdate' );

    # LiveJournal
    is( _gt( '<abbr class="updated" title="2012-01-17T12:00:00-05:00">' ),
        _TIMESTAMP_12_00_EST, '_guess_by_abbr_published_updated_date' );
    is( _gt( '<abbr class="published" title="2012-01-17T12:00:00-05:00">' ),
        _TIMESTAMP_12_00_EST, '_guess_by_abbr_published_updated_date' );
}

sub test_date_matching
{
    is(
        _ts_from_html( '<p>Tue, 28 Aug 2012 21:24:00 GMT</p>' ),
        _ts( 'Tue, 28 Aug 2012 21:24:00 GMT' ),
        'date_matching: RFC 822'
    );

    is(
        _ts_from_html( '<p>Thursday May 30, 2013 2:14 AM PT</p>' ),
        _ts( 'Thu, 30 May 2013 02:14:00 PDT' ),
        'date_matching: sfgate.com header'
    );

    is(
        _ts_from_html( '<p>9:24 pm, Tuesday, August 28, 2012</p>' ),
        _ts( 'Tue, 28 Aug 2012 21:24:00 GMT' ),
        'date_matching: sfgate.com article'
    );

    is(
        _ts_from_html( '<p>11.06.2012 11:56 p.m.</p>' ),
        _ts( 'Tue, 6 Nov 2012 23:56:00 GMT' ),
        'date_matching: noozhawk.com article'
    );

    is(
        _ts_from_html( '<p>7th November 2012</p>' ),
        _ts( 'Wed, 7 Nov 2012 12:00:00 GMT' ),
        'date_matching: punkpedagogy.tumblr.com'
    );

    is(
        _ts_from_html(
            <<EOF
            <div id="articleDate" class="articleDate">
                Posted:
                &nbsp;
                11/06/2012 08:30:20 PM PST
            </div>
            <div id="articleDate" class="articleSecondaryDate">
                <span class="updated" style="display:none;" title="2012-11-07T11:02:32Z">November 7, 2012 11:2 AM GMT</span>
                Updated:
                &nbsp;
                11/07/2012 03:02:32 AM PST
            </div>
EOF
        ),
        _ts( 'Tue, 6 Nov 2012 20:30:20 PST' ),
        'date_matching: mercurynews.com'
    );

    is(
        _ts_from_html( '<div class="noted">11/10/12<br>11:29pm</div>' ),
        _ts( 'Sat, 10 Nov 2012 23:29:00 GMT' ),
        'date_matching: registerguard.com'
    );

    is(
        _ts_from_html(
            <<EOF
            <p class="fontStyle21">
                Posted: 11/05/2012
                <br>
                Last Updated:
                207 days ago
            </p>
EOF
        ),
        _ts( 'Mon, 5 Nov 2012 12:00:00 GMT' ),
        'date_matching: turnto23.com'
    );
}

sub test_inapplicable
{
    is(
        _gr_url( 'http://www.easyvoterguide.org/propositions/' )->{ result },
        MediaWords::CM::GuessDate::Result::INAPPLICABLE,
        'inapplicable: no digits in URL'
    );
    is(
        _gr_url( 'http://www.calchannel.com/proposition-36-three-strikes-law/' )->{ result },
        MediaWords::CM::GuessDate::Result::INAPPLICABLE,
        'inapplicable: 404 Not Found'
    );
    is(
        _gr_url( 'http://www.15min.lt/////' )->{ result },
        MediaWords::CM::GuessDate::Result::INAPPLICABLE,
        'inapplicable: no path in URL'
    );
    is(
        _gr_url( 'http://en.wikipedia.org/wiki/1980s_in_fashion' )->{ result },
        MediaWords::CM::GuessDate::Result::INAPPLICABLE,
        'inapplicable: Wikipedia URL'
    );
    is(
        _gr_url( 'https://www.phpbb.com/community/viewforum.php?f=14' )->{ result },
        MediaWords::CM::GuessDate::Result::INAPPLICABLE,
        'inapplicable: phpBB forum'
    );
    is(
        _gr_url( 'https://twitter.com/ladygaga' )->{ result },
        MediaWords::CM::GuessDate::Result::INAPPLICABLE,
        'inapplicable: Twitter user URL'
    );
    is(
        _gr_url(
'https://www.facebook.com/notes/facebook-engineering/adding-face-to-every-ip-celebrating-ipv6s-one-year-anniversary/10151492544578920'
          )->{ result },
        MediaWords::CM::GuessDate::Result::INAPPLICABLE,
        'inapplicable: Facebook URL'
    );
    is(
        _gr_url( 'http://vimeo.com/blog/archive/year:2013' )->{ result },
        MediaWords::CM::GuessDate::Result::INAPPLICABLE,
        'inapplicable: looks like URL of archive'
    );
    is(
        _gr_url( 'http://www.timesunion.com/news/crime/article/3-strikes-law-reformed-fewer-harsh-sentences-4013514.php' )
          ->{ result },
        MediaWords::CM::GuessDate::Result::INAPPLICABLE,
        'inapplicable: timesunion.com HTTP 404 Not Found'
    );
    is(
        _gr_url( 'http://www.seattlepi.com/news/crime/article/ACLU-challenges-human-trafficking-initiative-4018819.php' )
          ->{ result },
        MediaWords::CM::GuessDate::Result::INAPPLICABLE,
        'inapplicable: seattlepi.com HTTP 404 Not Found'
    );
    is(
        _gr_url( 'http://www.kgoam810.com/Article.asp?id=2569360&spid=' )->{ result },
        MediaWords::CM::GuessDate::Result::INAPPLICABLE,
        'inapplicable: kgoam810.com HTTP access denied'
    );
}

sub main
{
    my $builder = Test::More->builder;
    binmode $builder->output,         ":utf8";
    binmode $builder->failure_output, ":utf8";
    binmode $builder->todo_output,    ":utf8";

    test_dates();
    test_date_matching();
    test_inapplicable();
}

main();

