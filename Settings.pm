package Plugins::MusicArtistInfo::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.musicartistinfo');

sub name {
	return 'PLUGIN_MUSICARTISTINFO';
}

sub prefs {
	return ($prefs, 'browseArtistPictures', 'runImporter', 'lookupArtistPictures', 'artistImageFolder');
}

sub page {
	return 'plugins/MusicArtistInfo/settings.html';
}

1;