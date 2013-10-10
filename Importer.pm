package Plugins::MusicArtistInfo::Importer;

use strict;

use Slim::Music::Import;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Scanner::API;

use Plugins::MusicArtistInfo::LFM;

my $log = logger('plugin.musicartistinfo');

my $newTracks = [];

sub initPlugin {
	my $class = shift;
	
	return unless preferences('plugin.musicartistinfo')->get('runImporter');

	Slim::Music::Import->addImporter($class, {
		'type'         => 'post',
		'weight'       => 85,
		'use'          => 1,
	});
	
	return 1;
}

my $i;

sub startScan {
	my $class = shift;
	
	# Find distinct artists to check for artwork
	my $artists = Slim::Schema->search('Contributor');

	my $progress = undef;
	my $count    = $artists->count || 0;

	if ($count) {
		$progress = Slim::Utils::Progress->new({ 
			'type'  => 'importer',
			'name'  => 'plugin_musicartistinfo_artistPhoto',
			'total' => $count,
			'bar'   => 1
		});
	}

	$i = 0;
	
	while ( _getArtistPhotoURL({
		artists           => $artists,
		count             => $count,
		progress          => $progress,
	}) ) {}
}


sub _getArtistPhotoURL {
	my $params = shift;

	# get next artist from db
	if ( my $artist = $params->{artists}->next ) {
		$params->{progress}->update( $artist->name );
		$i++ % 20 == 0 && Slim::Schema->forceCommit;

		Plugins::MusicArtistInfo::LFM->getArtistPhotos(undef, sub {}, {
			artist => $artist->name
		});

		return 1;
	}

	if ( my $progress = $params->{progress} ) {
		$progress->final($params->{count});
		$log->error( "getArtistPhotoURL finished in " . $progress->duration );
	}

	Slim::Music::Import->endImporter('plugin_musicartistinfo_artistPhoto');
	
	return 0;
}

1;