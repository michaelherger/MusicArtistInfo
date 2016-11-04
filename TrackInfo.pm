package Plugins::MusicArtistInfo::TrackInfo;

use strict;

use Slim::Menu::TrackInfo;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Log;

use Plugins::MusicArtistInfo::ChartLyrics;

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

	Slim::Menu::TrackInfo->registerInfoProvider( moremusicinfo => (
		func => \&_objInfoHandler,
		after => 'moreartistinfo',
	) );
}

sub _objInfoHandler {
	my ( $client, $url, $obj, $remoteMeta ) = @_;

	my ($title, $artist);
	
	if ( $obj && blessed $obj ) {
		if ($obj->isa('Slim::Schema::Track')) {
			$title  = $obj->title || $remoteMeta->{title};
			$artist = $obj->artistName || $remoteMeta->{artist};
		}
	}

	return unless $title && $artist;
	
	return {
		name => cstring($client, 'PLUGIN_MUSICARTISTINFO_LYRICS'),
		type => 'link',
		url => \&getLyrics,
		passthrough => [ {
			title  => $title,
			artist => $artist,
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
	
	if ($artist && $title) {
		$args = {
			title  => $title,
			artist => $artist
		};
	}

	if ( !($args && $args->{artist} && $args->{title}) ) {
		$request->addResult('error', 'No track found');
		$request->setStatusDone();
		return;
	}
	
	getLyrics($client,
		sub {
			my $items = shift || {};
			
			$items = $items->{items};

			if ( !$items || !ref $items || !scalar @$items ) {
				$request->addResult('error', 'unknown');
			}
			elsif ( $items->[0]->{error} ) {
				$request->addResult('error', $items->[0]->{error});
			}
			elsif ($items) {
				my $item = shift @$items;
				
				# CLI clients expect real line breaks, not literal \n
				$item->{name} =~ s/\\n/\n/g;
				$request->addResult('lyrics', $item->{name});
				$request->addResult('title', $args->{title}) if $args->{title};
				$request->addResult('artist', $args->{artist}) if $args->{artist};
			}

			$request->setStatusDone();
		},{
			isWeb  => $request->getParam('html'),
		}, $args
	);
}

sub getLyrics {
	my ($client, $cb, $params, $args) = @_;
	
	$params ||= {};
	$args   ||= {};
	
	my $title = _cleanupAlbumName($args->{title});
	
	main::DEBUGLOG && $log->debug("Getting lyrics for " . $args->{title} . ' by ' . $args->{artist});
	
	Plugins::MusicArtistInfo::ChartLyrics->searchLyricsDirect($args, sub {
		my $lyrics = shift;
		
		my $items = [];
		if ($lyrics) {
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

1;