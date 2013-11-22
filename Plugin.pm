package Plugins::MusicArtistInfo::Plugin;

use strict;
use base qw(Slim::Plugin::Base);

use vars qw($VERSION);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);

use Plugins::MusicArtistInfo::AlbumInfo;
use Plugins::MusicArtistInfo::ArtistInfo;

use constant CAN_IMAGEPROXY => (Slim::Utils::Versions->compareVersions($::VERSION, '7.8.0') >= 0);
use constant PLUGIN_TAG => 'musicartistinfo';

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
	});
	
	Plugins::MusicArtistInfo::AlbumInfo->init($class);
	Plugins::MusicArtistInfo::ArtistInfo->init($class);

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
			match => qr/last\.fm/,
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
	
	my $url   = 'plugins/' . PLUGIN_TAG . '/index.html';
	
	Slim::Web::Pages->addPageLinks( 'plugins', { PLUGIN_MUSICARTISTINFO_ALBUMS_MISSING_ARTWORK => $url } );
	Slim::Web::Pages->addPageLinks( 'icons', { PLUGIN_MUSICARTISTINFO_ALBUMS_MISSING_ARTWORK => "html/images/cover.png" });

	Slim::Web::Pages->addPageFunction( $url, sub {
		my $client = $_[0];
		
		Slim::Web::XMLBrowser->handleWebIndex( {
			client  => $client,
			feed    => \&getMissingArtworkAlbums,
			type    => 'link',
			title   => cstring($client, 'PLUGIN_MUSICARTISTINFO_ALBUMS_MISSING_ARTWORK'),
			timeout => 35,
			args    => \@_
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

=pod
sub getSmallArtworkAlbums {
	my ($client, $cb, $params, $args) = @_;

	# Find distinct albums to check for artwork.
	my $collate = Slim::Utils::OSDetect->getOS()->sqlHelperClass()->collate();
	my $rs = Slim::Schema->search('Genre', undef, { 'order_by' => "me.namesort $collate" });

	my $cache = Slim::Utils::ArtworkCache->new();
	my $sth = Slim::Schema->dbh->prepare("SELECT album, cover, coverid FROM tracks WHERE NOT coverid IS NULL GROUP BY album");
	$sth->execute();
	
	my $items = [];
	while ( my $track = $sth->fetchrow_hashref ) {
		my $size;
		$size = $track->{cover} if $track->{cover} =~ /^\d+$/;
		
		if ( !$size && -f $track->{cover} ) {
			$size = -s _;
		}
		
		# what's a reasonable threshold here? Doesn't make much sense with lossy jpg vs. lossless png etc.
		if ( $size && $size > 50000 ) {
			my $album = Slim::Schema->search('Album', {
				'me.id' => { '=' => $track->{album} }
			})->first;
			
			if ($album) {
				my $artist = $album->contributor->name;
				my $title  = $album->title;
				
				push @$items, {
					type => 'slideshow',
					image => '/music/' . $track->{coverid} . '/cover',
					name => $title . ' ' . cstring($client, 'BY') . " $artist",
					url  => \&Plugins::MusicArtistInfo::AlbumInfo::getAlbumCovers,
					passthrough => [{ 
						album  => $title,
						artist => $artist,
					}]
				};
			}
		}
	}
	
	$items = [ sort { lc($a->{name}) cmp lc($b->{name}) } @$items ];
	
	$cb->({
		items => $items,
	});
}
=cut

sub _lastfmImgProxy { if (CAN_IMAGEPROXY) {
	my ($url, $spec) = @_;
	
	#main::DEBUGLOG && $log->debug("Artwork for $url, $spec");

	my $size = Slim::Web::ImageProxy->getRightSize($spec, {
		252 => 252,
		500 => 500,
	});

	$url =~ s/serve\/(?:\d+|_)\//serve\/$size\// if $size;
	
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