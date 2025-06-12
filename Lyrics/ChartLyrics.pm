package Plugins::MusicArtistInfo::Lyrics::ChartLyrics;

use strict;

use File::Spec::Functions qw(catdir);
use FindBin qw($Bin);
use lib catdir($Bin, 'Plugins', 'MusicArtistInfo', 'lib');
use XML::Simple;
use URI::Escape qw(uri_escape_utf8);

use Slim::Utils::Log;

use constant BASE_URL => 'http://api.chartlyrics.com/apiv1.asmx/';
use constant SEARCH_URL => BASE_URL . 'SearchLyric?artist=%s&song=%s';
use constant SEARCH_DIRECT_URL => BASE_URL . 'SearchLyricDirect?artist=%s&song=%s';
use constant GET_LYRICS_URL => BASE_URL . 'GetLyric?lyricId=%s&lyricCheckSum=%s';

# max. editing distance as found by Levenshtein algorithm
use constant MAX_DISTANCE => 6;

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

			if ($items && ref $items && $items->{error} && $items->{error} =~ /timed out|403 forbidden/i) {
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
		return $cb->();
	}

	$class->searchLyrics( $args, sub {
		my $items = shift;

		if ($items && $items->{SearchLyricResult} && ref $items->{SearchLyricResult} && ref $items->{SearchLyricResult} eq 'ARRAY' ) {
			my $artist = my $artist2 = lc($args->{artist});
			$artist2 =~ s/&/and/g;
			my $title  = lc($args->{title});

			# try exact match first
			my ($match) = grep {
				my $currentArtist = lc($_->{Artist});
				($artist eq $currentArtist || $artist2 eq $currentArtist) && $title eq lc($_->{Song});
			} @{ $items->{SearchLyricResult} };

			# try exact song title next...
			if (!$match) {
				($match) = grep {
					$title eq lc($_->{Song}) && ($artist =~ /\Q$_->{Artist}\E/i || $_->{Artist} =~ /\Q$artist\E/i || $artist2 =~ /\Q$_->{Artist}\E/i || $_->{Artist} =~ /\Q$artist2\E/i);
				} @{ $items->{SearchLyricResult} };
			}

			# match anything...
			if (!$match) {
				require Text::Levenshtein;
				($match) = grep {
					($artist =~ /\Q$_->{Artist}\E/i || $_->{Artist} =~ /\Q$artist\E/i || $artist2 =~ /\Q$_->{Artist}\E/i || $_->{Artist} =~ /\Q$artist2\E/i)
					&& ($title =~ /\Q$_->{Song}\E/i || $_->{Song} =~ /\Q$title\E/i)
					&& Text::Levenshtein::distance($args->{artist}, $_->{Artist}) <= MAX_DISTANCE
					&& Text::Levenshtein::distance($args->{title}, $_->{Song}) <= MAX_DISTANCE;
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