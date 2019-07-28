package Plugins::MusicArtistInfo::Lyrics::ChartLyrics;

use strict;
use XML::Simple;
use URI::Escape qw(uri_escape_utf8);

use Slim::Utils::Log;

use constant BASE_URL => 'http://api.chartlyrics.com/apiv1.asmx/';
use constant SEARCH_URL => BASE_URL . 'SearchLyric?artist=%s&song=%s';
use constant SEARCH_DIRECT_URL => BASE_URL . 'SearchLyricDirect?artist=%s&song=%s';
use constant GET_LYRICS_URL => BASE_URL . 'GetLyric?lyricId=%s&lyricCheckSum=%s';

my $log = logger('plugin.musicartistinfo');

# sometimes ChartLyrics is down for days - skip it if needed
use constant RETRY_AFTER => 3600;
my $nextTry = 0;

sub searchLyrics {
	my ( $class, $args, $cb ) = @_;

	Plugins::MusicArtistInfo::Common->call(
		sprintf(SEARCH_URL, uri_escape_utf8($args->{artist}), uri_escape_utf8($args->{title})),
		sub {
			my $items = shift;

			if ($items && ref $items && $items->{error} && $items->{error} =~ /timed out/i) {
				$nextTry = time + RETRY_AFTER;
			}

			if ($items && ref $items && $items->{SearchLyricResult} && ref $items->{SearchLyricResult}) {
				$cb->($items);
				return;
			}

			$cb->();
		},{
			timeout => 5,
			wantError => 1,
		}
	);

	return;
}

=pod
sub searchLyricsDirect {
	my ( $class, $args, $cb ) = @_;

	Plugins::MusicArtistInfo::Common->call( sprintf(SEARCH_DIRECT_URL, uri_escape_utf8($args->{artist}), uri_escape_utf8($args->{title})), sub {
		my $items = shift;

		if ($items && ref $items && $items->{Lyric} && !ref $items->{Lyric}) {
			$cb->(_normalize($items));
			return;
		}

		$cb->();
	});

	return;
}
=cut

sub getLyrics {
	my ( $class, $args, $cb ) = @_;

	Plugins::MusicArtistInfo::Common->call( sprintf(GET_LYRICS_URL, uri_escape_utf8($args->{id}), uri_escape_utf8($args->{checksum})), sub {
		my $items = shift;

		if ($items && ref $items && $items->{Lyric} && !ref $items->{Lyric}) {
			$cb->(_normalize($items));
			return;
		}

		$cb->();
	},{
		timeout => 5,
	});

	return;
}

sub searchLyricsInDirect {
	my ( $class, $args, $cb ) = @_;

	if (time < $nextTry) {
		main::INFOLOG && $log->is_info && $log->info('Skipping ChartLyrics, as it has been down recently, trying again in ' . ($nextTry - time));
		$cb->();
	}

	$class->searchLyrics( $args, sub {
		my $items = shift;

		if ($items && $items->{SearchLyricResult} && ref $items->{SearchLyricResult} && ref $items->{SearchLyricResult} eq 'ARRAY' ) {
			my $artist = lc($args->{artist});
			my $title  = lc($args->{title});

			# try exact match first
			my ($match) = grep {
				$artist eq lc($_->{Artist}) && $title eq lc($_->{Song});
			} @{ $items->{SearchLyricResult} };

			# try exact song title next...
			if (!$match) {
				($match) = grep {
					$title eq lc($_->{Song}) && ($artist =~ /\Q$_->{Artist}\E/i || $_->{Artist} =~ /\Q$artist\E/i);
				} @{ $items->{SearchLyricResult} };
			}

			# match anything...
			if (!$match) {
				($match) = grep {
					($artist =~ /\Q$_->{Artist}\E/i || $_->{Artist} =~ /\Q$artist\E/i) && ($title =~ /\Q$_->{Song}\E/i || $_->{Song} =~ /\Q$title\E/i);
				} @{ $items->{SearchLyricResult} };
			}

			if ( $match && ref $match && $match->{LyricId} && $match->{LyricChecksum} ) {
				$class->getLyrics( {
					id => $match->{LyricId},
					checksum => $match->{LyricChecksum}
				}, sub {
					$cb->(@_);
				} );
				return;
			}
		}

		$cb->();
	} );

	return;
}

sub _normalize {
	my ($item) = @_;

	return {
		lyrics => $item->{Lyric},
		artist => $item->{LyricArtist},
		song   => $item->{LyricSong}
	};
}

1;