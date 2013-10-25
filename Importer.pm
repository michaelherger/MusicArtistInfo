package Plugins::MusicArtistInfo::Importer;

use strict;
use Digest::MD5;
use File::Spec::Functions;
use File::Slurp;
use LWP::UserAgent;

use Slim::Music::Import;
use Slim::Utils::ArtworkCache;
use Slim::Utils::ImageResizer;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Scanner::API;

use Plugins::MusicArtistInfo::LFM;
use Plugins::MusicArtistInfo::LocalArtwork;

use constant EXPIRY => 60 * 86400;

my $log = logger('plugin.musicartistinfo');
my $prefs = preferences('plugin.musicartistinfo');

my $newTracks = [];
my ($ua, $cache, $cachedir, $imgProxyCache, $specs, $max, $precacheArtwork);

sub initPlugin {
	my $class = shift;
	
	$precacheArtwork = preferences('server')->get('precacheArtwork');
	
	return unless $prefs->get('runImporter') && ($precacheArtwork || $prefs->get('lookupArtistPictures'));

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
	
	$ua = LWP::UserAgent->new(
		agent   => Slim::Utils::Misc::userAgentString(),
		timeout => 15,
	) if $prefs->get('lookupArtistPictures');
		
 	$imgProxyCache = Slim::Utils::DbArtworkCache->new(undef, 'imgproxy', time() + EXPIRY);
 	$cache         = Slim::Utils::Cache->new();
	$cachedir      = preferences('server')->get('cachedir');

	$specs = join(',', Slim::Music::Artwork::getResizeSpecs());
		
	($max) = $specs =~ /(\d+)/;
	if ($max*1) {
		# 252 & 500 are known sizes for last.fm
		if    ($max <= 252) { $max = 252 }
		elsif ($max <= 500) { $max = 500 }
		else  { $max = 0 }
	}
	
	while ( _getArtistPhotoURL({
		artists  => $artists,
		count    => $count,
		progress => $progress,
	}) ) {}
	
	$imgProxyCache->{default_expires_in} = 86400 * 30;
}


sub _getArtistPhotoURL {
	my $params = shift;

	# get next artist from db
	if ( my $artist = $params->{artists}->next ) {
		$params->{progress}->update( $artist->name );
		$i++ % 5 == 0 && Slim::Schema->forceCommit;
		
		main::DEBUGLOG && $log->debug("Getting artwork for " . $artist->name);
		
		if ( my $file = Plugins::MusicArtistInfo::LocalArtwork->getArtistPhoto({
			artist_id => $artist->id,
			artist    => $artist->name,
			rawUrl    => 1,		# don't return the proxied URL, we want the raw file
			force     => 1,		# don't return cached value, this is a scan
		}) ) {
			_precacheArtistImage($artist->id, $file);
		}
		elsif ($ua) {		# only defined if $prefs->get('lookupArtistPictures')
			Plugins::MusicArtistInfo::LFM->getArtistPhoto(undef, sub {
				_precacheArtistImage($artist->id, @_);
			}, {
				artist => $artist->name
			});
		}

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
	
	return unless $precacheArtwork;
	
	if ( $artist_id && ref $img eq 'HASH' && (my $url = $img->{url}) ) {
		if ( !$max && (($img->{width} && $img->{width} > 1500) || ($img->{height} && $img->{height} > 1500)) ) {
			main::INFOLOG && $log->is_info && $log->info("Full size image is huge - try smaller copy instead (500px)\n" . Data::Dump::dump($img));
			$max = 500;
		}

		$url =~ s/\/_\//\/$max\// if $max;
		
		main::DEBUGLOG && $log->debug("Getting $url to be pre-cached");
		
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
		
		# use distributed expiry to not have to update everything at the same time
		$imgProxyCache->{default_expires_in} = time() + int(rand(EXPIRY));

		Slim::Utils::ImageResizer->resize($tmpFile, "imageproxy/mai/artist/$artist_id/image_", $specs, undef, $imgProxyCache );
		
		unlink $tmpFile;
	}
	elsif ( $artist_id && $img && -f $img ) {
		Slim::Utils::ImageResizer->resize($img, "imageproxy/mai/artist/$artist_id/image_", $specs, undef, $imgProxyCache );
	}
}

1;