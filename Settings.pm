package Plugins::MusicArtistInfo::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

use Plugins::MusicArtistInfo::Common qw(CAN_IMAGEPROXY CAN_ONLINE_LIBRARY);

my $prefs = preferences('plugin.musicartistinfo');
my $serverprefs = preferences('server');

sub name {
	return 'PLUGIN_MUSICARTISTINFO';
}

sub prefs {
	return ($prefs, qw(browseArtistPictures runImporter lookupArtistPictures lookupCoverArt reviewFolder artistImageFolder lyricsFolder bioFolder
		lookupAlbumArtistPicturesOnly saveMissingArtistPicturePlaceholder));
}

sub page {
	return 'plugins/MusicArtistInfo/settings.html';
}

sub handler {
	my ($class, $client, $paramRef, $pageSetup) = @_;

	# artfolder is a server setting - need to handle it manually
	if ($paramRef->{'saveSettings'}) {
		$serverprefs->set('artfolder', $paramRef->{artfolder});

		# XXX - what's wrong here? We should not need to do this!
		my (undef, @prefs) = $class->prefs();
		foreach (@prefs) {
			$paramRef->{"pref_$_"} ||= '';
		}
	}

	$paramRef->{noImageProxy} = !CAN_IMAGEPROXY;
	$paramRef->{canOnlineLibrary} = CAN_ONLINE_LIBRARY;
	$paramRef->{artfolder} = $serverprefs->get('artfolder');

	if ( $paramRef->{artfolder} && !(-d $paramRef->{artfolder} && -w _) ) {
		$paramRef->{saveAlbumCoversDisabled} = 1;
	}

	$class->SUPER::handler($client, $paramRef, $pageSetup)
}

1;