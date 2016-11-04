package Plugins::MusicArtistInfo::ChartLyrics;

use strict;
use XML::Simple;

use Encode;
#use FindBin qw($Bin);
#use lib catdir($Bin, 'Plugins', 'MusicArtistInfo', 'lib');
use URI::Escape qw(uri_escape_utf8);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
#use Slim::Utils::Strings qw(string cstring);

use constant BASE_URL => 'http://api.chartlyrics.com/apiv1.asmx/';
use constant SEARCH_URL => BASE_URL . 'SearchLyric?artist=%s&song=%s';
use constant SEARCH_DIRECT_URL => BASE_URL . 'SearchLyricDirect?artist=%s&song=%s';

my $log = logger('plugin.musicartistinfo');

sub searchLyrics {
	my ( $class, $args, $cb ) = @_;
	
	Plugins::MusicArtistInfo::Common->call( 
		sprintf(SEARCH_URL, uri_escape_utf8($args->{artist}), uri_escape_utf8($args->{title})), 
		sub {
			my $items = shift;
			
		if ($items && ref $items && $items->{SearchLyricResult} && ref $items->{SearchLyricResult}) {
			my $artist = $args->{artist};
			my $title  = $args->{title};
			
			my ($match) = grep {
				$artist =~ /\Q$_->{Artist}\E/i && $title =~ /\Q$_->{Song}\E/i;
			} @{ $items->{SearchLyricResult }};
			
			warn Data::Dump::dump($items, $match, 'yo');
		}
			
			# $cb->();
		}
	);
	
	return;
}

sub searchLyricsDirect {
	my ( $class, $args, $cb ) = @_;
	
	Plugins::MusicArtistInfo::Common->call( sprintf(SEARCH_DIRECT_URL, uri_escape_utf8($args->{artist}), uri_escape_utf8($args->{title})), sub {
		my $items = shift;
		
		my $lyrics;
		
		if ($items && ref $items && $items->{Lyric} && !ref $items->{Lyric}) {
			$lyrics = $items->{LyricSong} if $items->{LyricSong};
			$lyrics .= ' - ' if $lyrics && $items->{LyricArtist};
			$lyrics .= $items->{LyricArtist} if $items->{LyricArtist};
			$lyrics .= "\n\n" if $lyrics;
			$lyrics .= $items->{Lyric} if $items->{Lyric};
		}
		
		$cb->($lyrics);
	});
	
	return;
}

1;