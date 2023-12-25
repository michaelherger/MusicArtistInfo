package Plugins::MusicArtistInfo::Lyrics::LRCLib;

use strict;

use List::Util qw(min max);
use URI::Escape qw(uri_escape_utf8);

use Slim::Utils::Prefs;

use constant BASE_URL => 'https://lrclib.net/';
use constant GET_URL => BASE_URL . 'api/get?artist_name=%s&track_name=%s&album_name=%s&duration=%s';
use constant SEARCH_URL => BASE_URL . 'api/search?artist_name=%s&track_name=%s&album_name=%s';

# if we have different durations in a search result, accept a maximum difference of X seconds
use constant MAX_DURATION_DIFF => 5;

my $prefs = preferences('plugin.musicartistinfo');

sub getLyrics {
	my ( $class, $args, $cb ) = @_;

	return $cb->() unless $args->{album} && $args->{duration};

	Plugins::MusicArtistInfo::Common->call(
		sprintf(GET_URL, uri_escape_utf8($args->{artist}), uri_escape_utf8($args->{title}), uri_escape_utf8($args->{album} || '.'), $args->{duration} || 1),
		sub {
			my $result = shift;

			if ($result && ref $result && ($result->{plainLyrics} || $result->{syncedLyrics})) {
				return $cb->({
					song => $args->{title},
					artist => $args->{artist},
					lyrics => $result->{syncedLyrics} || $result->{plainLyrics},
				});
			}

			$cb->();
		},{
			timeout => 10,
			ignoreError => [404]
		}
	);

	return;
}


sub searchLyrics {
	my ( $class, $args, $cb ) = @_;

	Plugins::MusicArtistInfo::Common->call(
		sprintf(SEARCH_URL, uri_escape_utf8($args->{artist}), uri_escape_utf8($args->{title}), uri_escape_utf8($args->{album})),
		sub {
			my $result = shift;

			if ($result && ref $result && ref $result eq 'ARRAY' && scalar @$result) {
				my $artist = lc($args->{artist});
				my $track  = lc($args->{title});

				my ($min, $max);
				foreach (@$result) {
					$min ||= $_->{duration};
					$max ||= $_->{duration};
					$min = min($min, $_->{duration});
					$max = max($max, $_->{duration});
				}

				my $useSynced = (($max - $min) <= MAX_DURATION_DIFF);

				my ($lyrics) = grep {
					$_ && ref $_ && ($_->{plainLyrics} || $_->{syncedLyrics}) && lc($_->{artistName}) eq $artist && lc($_->{trackName}) eq $track;
				} @$result;

				if (!$lyrics) {
					($lyrics) = grep {
						$_ && ref $_ && ($_->{plainLyrics} || $_->{syncedLyrics}) && $_->{artist} =~ /\Q$artist\E/i && $_->{trackName} =~ /\Q$track\E/i;
					} @$result;
				}

				return $cb->({
					song => $lyrics->{title},
					artist => $lyrics->{artist},
					lyrics => ($useSynced && $lyrics->{syncedLyrics}) || $lyrics->{plainLyrics},
				}) if $lyrics;
			}

			$cb->();
		},{
			timeout => 10,
			ignoreError => [404]
		}
	);

	return;
}

1;