package Plugins::MusicArtistInfo::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

use Plugins::MusicArtistInfo::Common qw(CAN_IMAGEPROXY CAN_ONLINE_LIBRARY CAN_LMS_ARTIST_ARTWORK isDirWritable);

my $prefs = preferences('plugin.musicartistinfo');
my $serverprefs = preferences('server');

sub name {
	return 'PLUGIN_MUSICARTISTINFO';
}

sub prefs {
	my @prefs = ($prefs, qw(runImporter lookupArtistPictures lookupCoverArt reviewFolder artistImageFolder lyricsFolder bioFolder
		lookupAlbumArtistPicturesOnly saveMissingArtistPicturePlaceholder replaceOnlineGenres useAIGeneratedContent preferredLanguage
		hidextramenusitems));

	# we'll leave the artist picture handling to LMS, if possible
	push @prefs, 'browseArtistPictures' if !CAN_LMS_ARTIST_ARTWORK;

	return @prefs;
}

sub page {
	return 'plugins/MusicArtistInfo/settings.html';
}

sub handler {
	my ($class, $client, $paramRef, $pageSetup) = @_;

	# update the lyrics providers to let users force-refresh the list without restarting LMS...
	Plugins::MusicArtistInfo::TrackInfo->updateLyricsProviders();

	# artfolder is a server setting - need to handle it manually
	if ($paramRef->{'saveSettings'}) {
		$serverprefs->set('artfolder', $paramRef->{artfolder});

		# XXX - what's wrong here? We should not need to do this!
		my (undef, @prefs) = $class->prefs();
		foreach (@prefs) {
			$paramRef->{"pref_$_"} ||= '';
		}
	}

	$paramRef->{hitRateLimit} = Plugins::MusicArtistInfo::API::hasHitRateLimit();
	$paramRef->{noImageProxy} = !CAN_IMAGEPROXY;
	$paramRef->{canLMSArtistArtwork} = CAN_LMS_ARTIST_ARTWORK;
	$paramRef->{canOnlineLibrary} = CAN_ONLINE_LIBRARY;
	$paramRef->{artfolder} = $serverprefs->get('artfolder');
	$paramRef->{languageOptions} = Slim::Utils::Strings::languageOptions();
	$paramRef->{contentLanguages} = Plugins::MusicArtistInfo::Common::getContentLanguages();
	$paramRef->{lmsLanguage} = preferences('server')->get('language');

	if ( $paramRef->{artfolder} && !isDirWritable($paramRef->{artfolder}) ) {
		$paramRef->{saveAlbumCoversDisabled} = 1;
	}

	$class->SUPER::handler($client, $paramRef, $pageSetup)
}

1;