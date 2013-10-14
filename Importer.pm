package Plugins::MusicArtistInfo::Importer;

use strict;

use Slim::Music::Import;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Scanner::API;

use Plugins::MusicArtistInfo::LFM;

my $log = logger('plugin.musicartistinfo');
my $prefs = preferences('plugin.musicartistinfo');

my $newTracks = [];
my ($ua, $cache, $cachedir, $imgProxyCache, $specs);

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
	
	my $precacheCB = sub {};
	
	if ($prefs->get('precacheArtistPictures')) {
		require Digest::MD5;
		require File::Spec::Functions;
		require File::Slurp;
		require LWP::UserAgent;
		require Slim::Utils::ArtworkCache;
		require Slim::Utils::ImageResizer;

		$precacheCB = \&_precacheArtistImage;
		$ua = LWP::UserAgent->new(
			agent   => Slim::Utils::Misc::userAgentString(),
			timeout => 15,
		);
		
	 	$imgProxyCache = Slim::Utils::DbArtworkCache->new(undef, 'imgproxy');
	 	$cache = Slim::Utils::Cache->new();
	 	$cachedir = preferences('server')->get('cachedir');

		my $thumbSize = $prefs->get('thumbSize') || 100;
		$specs = join(',', Slim::Music::Artwork::getResizeSpecs());
	}
	
	while ( _getArtistPhotoURL({
		artists  => $artists,
		count    => $count,
		progress => $progress,
		cb       => $precacheCB,
	}) ) {}
}


sub _getArtistPhotoURL {
	my $params = shift;

	# get next artist from db
	if ( my $artist = $params->{artists}->next ) {
		$params->{progress}->update( $artist->name );
		$i++ % 5 == 0 && Slim::Schema->forceCommit;

		Plugins::MusicArtistInfo::LFM->getArtistPhoto(undef, sub {
			$params->{cb}->($artist->id, @_);
		}, {
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

sub _precacheArtistImage {
	my ($artist_id, $img) = @_;
	
	if ( $artist_id && (my $url = $img->{url}) ) {
		if ( ($img->{width} && $img->{width} > 1500) || ($img->{height} && $img->{height} > 1500) ) {
			main::INFOLOG && $log->is_info && $log->info("Full size image is huge - try smaller copy instead (500px)\n" . Data::Dump::dump($img));
			$url =~ s/\/_\//\/500\//;
		}
		
#		main::DEBUGLOG && $log->debug("Getting $url to be pre-cached");
		
		my $tmpFile = File::Spec::Functions::catdir( $cachedir, 'imgproxy_' . Digest::MD5::md5_hex($url) );

		if (my $image = $cache->get("mai_$url")) {
			File::Slurp::write_file($tmpFile, $image);
		}
		else {
			my $response = $ua->get( $url, ':content_file' => $tmpFile );
			if ($response && $response->is_success) {
				$cache->set("mai_$url", scalar File::Slurp::read_file($tmpFile, binmode => ':raw'));
			}
			else {
				$log->warn("Image download failed for $url: " . $response->message);
			}
		}
		
		return unless -f $tmpFile;
		
		my $cachekey = "imageproxy/mai/artist/$artist_id/image_";
		Slim::Utils::ImageResizer->resize($tmpFile, $cachekey, $specs, undef, $imgProxyCache );
		
		unlink $tmpFile;
	}
}

1;