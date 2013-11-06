package Plugins::MusicArtistInfo::ImporterHelper;

# this is a helper class to only load the actual importer if LMS is compatible

use strict;
use constant CAN_IMAGEPROXY => (Slim::Utils::Versions->compareVersions($::VERSION, '7.8.0') >= 0);

sub initPlugin { if (CAN_IMAGEPROXY) {
	my $class = shift;

	require Plugins::MusicArtistInfo::Importer;
	return Plugins::MusicArtistInfo::Importer->initPlugin(@_);
} }

sub startScan { if (CAN_IMAGEPROXY) {
	my $class = shift;

	require Plugins::MusicArtistInfo::Importer;
	return Plugins::MusicArtistInfo::Importer->starScan(@_);
} }

1;