package Plugins::MusicArtistInfo::TrackInfo;

use strict;

use Slim::Menu::TrackInfo;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Log;
use Slim::Utils::Misc;

use Plugins::MusicArtistInfo::ChartLyrics;
use Plugins::MusicArtistInfo::LRCParser;

*_cleanupAlbumName = \&Plugins::MusicArtistInfo::Common::cleanupAlbumName;

use constant CLICOMMAND => 'musicartistinfo';

my $log = logger('plugin.musicartistinfo');

sub init {
#                                                                |requires Client
#                                                                |  |is a Query
#                                                                |  |  |has Tags
#                                                                |  |  |  |Function to call
#                                                                C  Q  T  F
	Slim::Control::Request::addDispatch([CLICOMMAND, 'lyrics'], [0, 1, 1, \&getSongLyricsCLI]);

	Slim::Menu::TrackInfo->registerInfoProvider( moretrackinfo => (
		func => \&_objInfoHandler,
		after => 'moreartistinfo',
	) );
}

sub _objInfoHandler {
	my ( $client, $url, $obj, $remoteMeta ) = @_;

	my ($title, $artist, $id);

	if ( $obj && blessed $obj ) {
		if ($obj->isa('Slim::Schema::Track')) {
			$id     = $obj->id;
			$title  = $obj->title;
			$artist = $obj->artistName;
		}
	}

	$remoteMeta ||= {};
	$title ||= $remoteMeta->{title};
	$artist ||= $remoteMeta->{artist};

	if ( !($title && $artist) && $obj->remote ) {
		my $request = Slim::Control::Request::executeRequest($client, ['status', 0, 10]);
		my $remoteMeta = $request->getResult('remoteMeta');

		$title ||= $remoteMeta->{title};
		$artist ||= $remoteMeta->{artist};
	}

	return unless $id || ($title && $artist);

	return {
		name => cstring($client, 'PLUGIN_MUSICARTISTINFO_LYRICS'),
		type => 'link',
		url => \&getLyrics,
		passthrough => [ {
			id     => $id,
			title  => $title,
			artist => $artist,
			url    => $url,
		} ],
	};
}

sub getSongLyricsCLI {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([[CLICOMMAND], ['lyrics']])) {
		$request->setStatusBadDispatch();
		return;
	}

	$request->setStatusProcessing();

	my $client = $request->client();

	my $args;
	my $artist = $request->getParam('artist');
	my $title  = $request->getParam('title');
	my $id     = $request->getParam('track_id');
	my $url    = $request->getParam('url');

	if (my $lyrics = _getLocalLyrics($id, $url)) {
		$lyrics =~ s/\\n/\n/g;
		$request->addResult('lyrics', $lyrics);
		$request->addResult('title', $args->{title}) if $title;
		$request->addResult('artist', $args->{artist}) if $artist;
		$request->setStatusDone();
		return;
	}

	if ($artist && $title) {
		$args = {
			title  => $title,
			artist => $artist
		};
	}

	if ( !($args && $args->{artist} && $args->{title}) ) {
		$request->addResult('error', cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND'));
		$request->setStatusDone();
		return;
	}

	Plugins::MusicArtistInfo::ChartLyrics->searchLyricsInDirect($args, sub {
		my $item = shift || {};

		if ( !$item || !ref $item ) {
			$request->addResult('error', cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND'));
		}
		elsif ( $item->{error} ) {
			$request->addResult('error', $item->{error});
		}
		elsif ($item) {
			my $lyrics = _renderLyrics($item);

			# CLI clients expect real line breaks, not literal \n
			$lyrics =~ s/\\n/\n/g;
			$request->addResult('lyrics', $lyrics) if $lyrics;
			$request->addResult('error', cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND')) unless $lyrics;
			$request->addResult('title', $args->{title}) if $args->{title};
			$request->addResult('artist', $args->{artist}) if $args->{artist};
			$request->addResult('lyricUrl', $item->{LyricUrl}) if $item->{LyricUrl};
		}

		$request->setStatusDone();
	});
}

sub getLyrics {
	my ($client, $cb, $params, $args) = @_;

	$params ||= {};
	$args   ||= {};

	main::DEBUGLOG && $log->debug("Getting lyrics for " . $args->{title} . ' by ' . $args->{artist});

	if (my $lyrics = _getLocalLyrics($args->{id}, $args->{url})) {
		my $responseText = '';
		$responseText = $args->{title} if $args->{title};
		$responseText .= ' - ' . $args->{artist} if $args->{artist};
		$responseText .= "\n\n";
		$responseText .= $lyrics;

		if ($cb) {
			$cb->({
				items => Plugins::MusicArtistInfo::Plugin->textAreaItem($client, $params->{isButton}, $responseText),
			});
		}

		return;
	}

	Plugins::MusicArtistInfo::ChartLyrics->searchLyricsInDirect($args, sub {
		my $items = shift;

		if ($items) {
			my $lyrics;
			$lyrics = $items->{LyricSong} if $items->{LyricSong};
			$lyrics .= ' - ' if $lyrics && $items->{LyricArtist};
			$lyrics .= $items->{LyricArtist} if $items->{LyricArtist};
			$lyrics .= "\n\n" if $lyrics;
			$lyrics .= $items->{Lyric} if $items->{Lyric};
			$lyrics .= "\n\n" . cstring($client, 'URL') . cstring($client, 'COLON') . ' ' . $items->{LyricUrl} if $items->{LyricUrl};

			$items = Plugins::MusicArtistInfo::Plugin->textAreaItem($client, $params->{isButton}, $lyrics);
		}
		else {
			$items = [{
				name => cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND'),
				type => 'textarea'
			}];
		}

		if ($cb) {
			$cb->({
				items => $items,
			});
		}
	});
}

sub _getLocalLyrics {
	my ($id, $url) = @_;

	my $track;
	if (defined $id){
		$track = Slim::Schema->find('Track', $id);
	} 
	elsif ($url) {
		$track = Slim::Schema->objectForUrl($url);
	}

	if ($track && (my $lyrics = $track->lyrics)) {
		return $lyrics;
	}

	$url ||= $track->url if $track;

	# try "Song.mp3.lrc" and "Song.lrc"
	if ($url) {
		my $filePath = Slim::Utils::Misc::pathFromFileURL($url);
		my $filePath2 = $filePath . '.lrc';
		$filePath =~ s/\.\w{2,4}$/.lrc/;
		return Plugins::MusicArtistInfo::LRCParser->parseLRC($filePath) || Plugins::MusicArtistInfo::LRCParser->parseLRC($filePath2);
	}

	return;
}

sub _renderLyrics {
	my $items = shift;

	my $lyrics = $items->{LyricSong} if $items->{LyricSong};
	$lyrics .= ' - ' if $lyrics && $items->{LyricArtist};
	$lyrics .= $items->{LyricArtist} if $items->{LyricArtist};
	$lyrics .= "\n\n" if $lyrics;
	$lyrics .= $items->{Lyric} if $items->{Lyric};

	return $lyrics;
}

1;