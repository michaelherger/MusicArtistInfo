package Plugins::MusicArtistInfo::Settings;

use strict;
use base qw(Slim::Web::Settings);

#use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Web::Settings::Server::Plugins;

my $prefs = preferences('plugin.musicartistinfo');
#my $log   = logger('plugin.smartmix');

sub name {
	return 'PLUGIN_MUSICARTISTINFO';
}

sub prefs {
	return ($prefs, 'browseArtistPictures', 'runImporter', 'precacheArtistPictures');
}

sub page {
	return 'plugins/MusicArtistInfo/settings.html';
}

1;