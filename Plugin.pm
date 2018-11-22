package Plugins::MusicArtistInfo::Plugin;

use strict;
use base qw(Slim::Plugin::Base);

use vars qw($VERSION);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);

use Plugins::MusicArtistInfo::AlbumInfo;
use Plugins::MusicArtistInfo::ArtistInfo;
use Plugins::MusicArtistInfo::TrackInfo;
use Plugins::MusicArtistInfo::LocalFile;

use constant CAN_IMAGEPROXY => (Slim::Utils::Versions->compareVersions($::VERSION, '7.8.0') >= 0);
use constant PLUGIN_TAG => 'musicartistinfo';

my $WEBLINK_SUPPORTED_UA_RE = qr/\b(?:iPeng|SqueezePad|OrangeSqueeze)\b/i;
my $WEBBROWSER_UA_RE = qr/\b(?:FireFox|Chrome|Safari)\b/i;

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.musicartistinfo',
	defaultLevel => 'ERROR',
	description  => 'PLUGIN_MUSICARTISTINFO',
} );

sub initPlugin {
	my $class = shift;
	
	$VERSION = $class->_pluginDataFor('version');

	my $prefs = preferences('plugin.musicartistinfo'); 
	$prefs->init({
		browseArtistPictures => 1,
		runImporter => 1,
		lookupArtistPictures => 1,
		lookupCoverArt => 1,
		lookupAlbumArtistPicturesOnly => 1,
	});
	
	Plugins::MusicArtistInfo::AlbumInfo->init($class);
	Plugins::MusicArtistInfo::ArtistInfo->init($class);
	Plugins::MusicArtistInfo::TrackInfo->init($class);
	Plugins::MusicArtistInfo::LocalFile->init($class);

	# no need to actually initialize the importer, as it will only be executed in the external scanner anyway
	# but we still need to tell the scanner that there are external importers to be run
	Slim::Music::Import->addImporter('Plugins::MusicArtistInfo::Importer', {
		'type'         => 'post',
		'weight'       => 85,
		'use'          => 1,
	}) if $prefs->get('runImporter');

	# "Local Artwork" requires LMS 7.8+, as it's using its imageproxy.
	if (CAN_IMAGEPROXY) {
		require Plugins::MusicArtistInfo::LocalArtwork;
		Plugins::MusicArtistInfo::LocalArtwork->init();
		
		# revert skin pref from previous skinning exercise...
		preferences('server')->set('skin', 'Default') if lc(preferences('server')->get('skin')) eq 'musicartistinfo';
		$prefs->remove('skinSet');

		require Slim::Web::ImageProxy;
		Slim::Web::ImageProxy->registerHandler(
			match => qr/la?st\.fm/,
			func  => \&_lastfmImgProxy,
		);

		Slim::Web::ImageProxy->registerHandler(
			match => qr/images-amazon\.com/,
			func  => \&_amazonImgProxy,
		);

		Slim::Web::ImageProxy->registerHandler(
			match => qr/upload\.wikimedia\.org/,
			func  => \&_wikimediaImgProxy,
		);
	}
	
	if (main::WEBUI) {
		require Plugins::MusicArtistInfo::Settings;
		Plugins::MusicArtistInfo::Settings->new();
	}
	
	$class->SUPER::initPlugin(shift);
}

# don't add this plugin to the Extras menu
sub playerMenu {}

sub webPages {
	my $class = shift;
	
	my $url = 'plugins/' . PLUGIN_TAG . '/missingartwork.html';
	
	Slim::Web::Pages->addPageLinks( 'plugins', { PLUGIN_MUSICARTISTINFO_ALBUMS_MISSING_ARTWORK => $url } );
	Slim::Web::Pages->addPageLinks( 'icons', { PLUGIN_MUSICARTISTINFO_ALBUMS_MISSING_ARTWORK => "html/images/cover.png" });

	Slim::Web::Pages->addPageFunction( $url, sub {
		my $client = $_[0];
		
		Slim::Web::XMLBrowser->handleWebIndex( {
			client => $client,
			path   => 'missingartwork.html',
			feed   => \&getMissingArtworkAlbums,
			type   => 'link',
			title  => cstring($client, 'PLUGIN_MUSICARTISTINFO_ALBUMS_MISSING_ARTWORK'),
			args   => \@_
		} );
	} );

	$url = 'plugins/' . PLUGIN_TAG . '/smallartwork.html';
	
	Slim::Web::Pages->addPageLinks( 'plugins', { PLUGIN_MUSICARTISTINFO_ALBUMS_SMALL_ARTWORK => $url } );
	Slim::Web::Pages->addPageLinks( 'icons', { PLUGIN_MUSICARTISTINFO_ALBUMS_SMALL_ARTWORK => "html/images/cover.png" });

	Slim::Web::Pages->addPageFunction( $url, sub {
		my $client = $_[0];
		
		Slim::Web::XMLBrowser->handleWebIndex( {
			client => $client,
			feed   => \&getSmallArtworkAlbums,
			path   => 'smallartwork.html',
			type   => 'link',
			title  => cstring($client, 'PLUGIN_MUSICARTISTINFO_ALBUMS_SMALL_ARTWORK'),
			args   => \@_
		} );
	} );
}

sub getMissingArtworkAlbums {
	my ($client, $cb, $params, $args) = @_;

	# Find distinct albums to check for artwork.
	my $collate = Slim::Utils::OSDetect->getOS()->sqlHelperClass()->collate();
	my $rs = Slim::Schema->search('Genre', undef, { 'order_by' => "me.namesort $collate" });

	my $albums = Slim::Schema->search('Album', {
		'me.artwork' => { '='  => undef },
	},{
		'order_by' => "me.titlesort $collate",
	});
	
	my $items = [];
	while ( my $album = $albums->next ) {
		my $artist = $album->contributor->name;
		
		push @$items, {
			type => 'slideshow',
			name => $album->title . ' ' . cstring($client, 'BY') . " $artist",
			url  => \&Plugins::MusicArtistInfo::AlbumInfo::getAlbumCovers,
			passthrough => [{ 
				album  => $album->title,
				artist => $artist,
			}]
		};
	}
	
	$cb->({
		items => $items,
	});
}

sub getSmallArtworkAlbums {
	my ($client, $cb, $params, $args) = @_;

	$args ||= {};
	my $minSize = $params->{search} || $args->{minSize};
	if (!$minSize) {
		my $items = [{
			name => cstring($client, 'PLUGIN_MUSICARTISTINFO_MIN_SIZE'),
			type => 'search',
			url  => \&getSmallArtworkAlbums,
		}];
		
		foreach (1500, 1000, 800, 500, 400, 300) {
			unshift @$items, {
				name => cstring($client, 'PLUGIN_MUSICARTISTINFO_MIN_SIZE_X', $_),
				type => 'link',
				url  => \&getSmallArtworkAlbums,
				passthrough => [{
					minSize => $_
				}],
			}
		}
		
		$cb->({
			items => $items,
		});
		return;
	}

	# this query is expensive - try to grab it from the cache
	my $cache = Slim::Utils::Cache->new();
	my $items = $cache->get('mai_smallartwork' . $minSize);
	
	if ($items) {
		$cb->({
			items => [ map { 
				$_->{url} = \&Plugins::MusicArtistInfo::AlbumInfo::getAlbumCovers;
				$_;
			} @$items ],
		});
		return;
	}
	
	require Slim::Utils::GDResizer;

	# Find distinct albums to check for artwork.
	my $sth = Slim::Schema->dbh->prepare("SELECT album, cover, url, coverid FROM tracks WHERE NOT coverid IS NULL GROUP BY album");
	$sth->execute();
	
	$items = [];
	while ( my $track = $sth->fetchrow_hashref ) {
		my $file = $track->{cover} =~ /^\d+$/
				? Slim::Utils::Misc::pathFromFileURL($track->{url})
				: $track->{cover};
		
		# skip files which don't exist
		if ( !$file || !-e $file ) {
			$log->warn("File doesn't exits: " . ($file || 'undef'));
			next;
		}

		my ($offset, $length, $origref);
		
		# Load image data from tags if necessary
		if ( $file && $file !~ /\.(?:jpe?g|gif|png)$/i ) {
			# Double-check that this isn't an image file
#			if ( !_content_type_file($file, 0, 1) ) {
				($offset, $length, $origref) = Slim::Utils::GDResizer::_read_tag($file);
			
				if ( !$offset ) {
					if ( !$origref ) {
						$log->error("Unable to find any image tag in $file");
						next;
					}
					
					$file = '';
				}
#			}
		}

		$origref ||= Slim::Utils::GDResizer::_slurp($file, $length ? $offset : undef, $length || undef) if $file;
		
		if ( !$origref ) {
			$log->error("Unable to find any image data in $file");
			next;
		}
		
		my ($w, $h) = Slim::Utils::GDResizer->getSize($origref);
		
		next if $w >= $minSize || $h >= $minSize;
		
		my $album = Slim::Schema->search('Album', {
			'me.id' => { '=' => $track->{album} }
		})->first;
		
		if ($album) {
			my $artist = $album->contributor->name;
			my $title  = $album->title;
			
			push @$items, {
				type => 'slideshow',
				image => '/music/' . $track->{coverid} . '/cover',
				name => $title . ' ' . cstring($client, 'BY') . " $artist (${w}x${h}px)",
#				url  => \&Plugins::MusicArtistInfo::AlbumInfo::getAlbumCovers,
				passthrough => [{ 
					album  => $title,
					artist => $artist,
				}]
			};
		}
		
		main::idleStreams();
	}
	
	$items = [ sort { lc($a->{name}) cmp lc($b->{name}) } @$items ];

	$cache->set('mai_smallartwork' . $minSize, $items, 60);
	
	$cb->({
		items => [ map { 
			$_->{url} = \&Plugins::MusicArtistInfo::AlbumInfo::getAlbumCovers;
			$_;
		} @$items ],
	});
}

sub canWeblink {
	my ($class, $client) = @_;
	return $client && $client->controllerUA && ($client->controllerUA =~ $WEBLINK_SUPPORTED_UA_RE || $client->controllerUA =~ $WEBBROWSER_UA_RE);
}

sub isWebBrowser {
	my ($class, $client, $params) = @_;
	return 1 if $params && $params->{isWeb};
	return $client && $client->controllerUA && $client->controllerUA =~ $WEBBROWSER_UA_RE;
}

my $canWrap;
sub textAreaItem {
	my ($class, $client, $isButton, $content) = @_;
	
	my @items;
	
	# ip3k doesn't support textarea - try to wrap
	if ($isButton) {
		if (!defined $canWrap) {
			eval { require Text::Wrap; };
			$canWrap = $@ ? 0 : 1;
		}
		
		$content =~ s/\\n/\n/g;
		
		if ($canWrap) {
			$Text::Wrap::columns = ($client && $client->isa("Slim::Player::Boom")) ? 20 : 35;
			@items = split(/\n/, Text::Wrap::wrap('', '', $content));
		}
		else {
			@items = split(/\n/, $content);
		}

		@items = map {
			{
				type => 'text',
				name => $_,
			}
		} grep { 
			$_ !~ /\[IMAGE\]/ 
		} grep /.+/, @items;
	}
	else {
		push @items, {
			name => $content,
			type => 'textarea',
		};
	}
	
	return \@items;
}

sub _lastfmImgProxy { if (CAN_IMAGEPROXY) {
	my ($url, $spec) = @_;
	
	#main::DEBUGLOG && $log->debug("Artwork for $url, $spec");

	my $size = Slim::Web::ImageProxy->getRightSize($spec, {
#		252 => 252,
		300 => '300x300',
	});

	if ($size) {
		$url =~ s/serve\/(?:\d+|_)\//serve\/$size\//;
		$url =~ s/(fm\/i\/u\/)([a-f0-9]{32,})/$1$size\/$2/;
	}
	
	#main::DEBUGLOG && $log->debug("Artwork file url is '$url'");

	return $url;
} }

sub _amazonImgProxy { if (CAN_IMAGEPROXY) {
	my ($url, $spec) = @_;
	
	#main::DEBUGLOG && $log->debug("Artwork for $url, $spec");

	my $size = minSize(Slim::Web::Graphics->parseSpec($spec)) || 500;
	$url =~ s/\._SL\d+_\./._SL${size}_./;

	#main::DEBUGLOG && $log->debug("Artwork file url is '$url'");

	return $url;
} }

sub _wikimediaImgProxy { if (CAN_IMAGEPROXY) {
	my ($url, $spec) = @_;
	
	#main::DEBUGLOG && $log->debug("Artwork for $url, $spec");

	my $size = minSize(Slim::Web::Graphics->parseSpec($spec)) || 500;

	# if url comes with resizing parameters already, only replace the size
	# http://upload.wikimedia.org/wikipedia/commons/thumb/e/ee/Radio_SRF_3.svg/500px-Radio_SRF_3.svg.png
	if ( $url =~ m|/thumb/.*/\d+px|i ) {
		$url =~ s/\/\d+px/\/$1${size}px/;
	}
	# otherwise fix url to get resized image
	# http://upload.wikimedia.org/wikipedia/commons/e/ee/Radio_SRF_3.svg
	elsif (my ($img) = $url =~ /\/([^\/]*?\.(?:jpe?g|png|svg|gif))$/) {
		$url =~ s/(\/commons\/)/${1}thumb\//;
		$url =~ s/$img/$img\/${size}px-$img/;
		$url =~ s/(\.svg)$/$1.png/;		
	}

	#main::DEBUGLOG && $log->debug("Artwork file url is '$url'");

	return $url;
} }

sub minSize {
	my ($width, $height) = @_;
	
	if ($width || $height) {
		$width  ||= $height;
		$height ||= $width;
		
		return ($width > $height ? $width : $height);
	}
	
	return 0;
}

1;