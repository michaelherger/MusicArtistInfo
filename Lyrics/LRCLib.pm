package Plugins::MusicArtistInfo::Lyrics::LRCLib;

use strict;

use URI::Escape qw(uri_escape_utf8);

use Slim::Utils::Prefs;

use constant BASE_URL => 'https://lrclib.net/';
use constant GET_URL => BASE_URL . 'api/get?artist_name=%s&track_name=%s&album_name=%s&duration=%s';
use constant SEARCH_URL => 'api/search?track_name=%s&artist_name=%s&album_name=%s';

my $prefs = preferences('plugin.musicartistinfo');

sub getLyrics {
	my ( $class, $args, $cb ) = @_;

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
			timeout => 5,
			ignoreError => [404]
		}
	);

	return;
}


1;