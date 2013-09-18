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

1;