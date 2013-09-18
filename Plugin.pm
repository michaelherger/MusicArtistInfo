package Plugins::MusicArtistInfo::Plugin;

use strict;
use base qw(Slim::Plugin::Base);

use vars qw($VERSION);

use Slim::Utils::Log;
use Slim::Utils::Strings qw(string cstring);

use Plugins::MusicArtistInfo::AlbumInfo;
use Plugins::MusicArtistInfo::ArtistInfo;

use constant PLUGIN_TAG => 'musicartistinfo';

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.musicartistinfo',
	defaultLevel => 'ERROR',
	description  => 'PLUGIN_MUSICARTISTINFO',
} );

sub initPlugin {
	my $class = shift;
	
	$VERSION = $class->_pluginDataFor('version');
	
	Plugins::MusicArtistInfo::AlbumInfo->init($class->_pluginDataFor('id2'));
	Plugins::MusicArtistInfo::ArtistInfo->init($class->_pluginDataFor('id1'));

	# "Local Artwork" requires LMS 7.8+, as it's using its imageproxy.
	if (Slim::Utils::Versions->compareVersions($::VERSION, '7.8.0') >= 0) {
		require Plugins::MusicArtistInfo::LocalArtwork;
		Plugins::MusicArtistInfo::LocalArtwork->init();
	}
	
	$class->SUPER::initPlugin(shift);
}

# don't add this plugin to the Extras menu
sub playerMenu {}

sub webPages {
	my $class = shift;
	
	my $title = string('PLUGIN_MUSICARTISTINFO_ALBUMS_MISSING_ARTWORK');
	my $url   = 'plugins/' . PLUGIN_TAG . '/index.html';
	
	Slim::Web::Pages->addPageLinks( 'plugins', { $title => $url } );

	Slim::Web::Pages->addPageFunction( $url, sub {
		my $client = $_[0];
		
		Slim::Web::XMLBrowser->handleWebIndex( {
			client  => $client,
			feed    => \&getMissingArtworkAlbums,
			type    => 'link',
			title   => $title,
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
			url  => \&Plugins::MusicArtistInfo::AlbumInfo::getAlbumCover,
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

1;