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

use constant BASE_URL => 'http://api.chartlyrics.com/apiv1.asmx/SearchLyricDirect?artist=%s&song=%s';

my $log = logger('plugin.musicartistinfo');


sub getLyricsDirect {
	my ( $class, $args, $cb ) = @_;
	
	
	call($args, sub {
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

sub call {
	my ($args, $cb) = @_;

	my $params = {};
	$params->{timeout} ||= 15;

	my $url = sprintf(BASE_URL, uri_escape_utf8($args->{artist}), uri_escape_utf8($args->{title})), 
	
	my $cb2 = sub {
		my $response = shift;
		
		main::DEBUGLOG && $log->is_debug && $response->code !~ /2\d\d/ && $log->debug(Data::Dump::dump($response, @_));
		my $result = eval { XMLin( $response->content ) };
	
		$result ||= {};
		
		if ($@) {
			 $log->error($@);
			 $result->{error} = $@;
		}

		main::DEBUGLOG && $log->is_debug && warn Data::Dump::dump($result);
			
		$cb->($result);
	};
	
	Slim::Networking::SimpleAsyncHTTP->new( 
		$cb2,
		$cb2,
		$params
	)->get($url);
}

1;