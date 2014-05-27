package Plugins::MusicArtistInfo::Importer2;

use strict;
use Digest::MD5;
use File::Spec::Functions qw(catdir);
use File::Slurp;
use LWP::UserAgent;

use Slim::Music::Import;
use Slim::Utils::ArtworkCache;
use Slim::Utils::ImageResizer;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::MusicArtistInfo::LFM;
use Plugins::MusicArtistInfo::LocalArtwork;

my $log = logger('plugin.musicartistinfo');
my $prefs = preferences('plugin.musicartistinfo');
my $serverprefs = preferences('server');

my ($i, $ua, $cache, $cachedir, $imgProxyCache, $specs, $testSpec, $max, $precacheArtwork, $imageFolder);

sub startScan {
	my $class = shift;
	
	$precacheArtwork = $serverprefs->get('precacheArtwork');
			
	$imageFolder = $prefs->get('artistImageFolder');
	$imageFolder = undef unless $imageFolder && -d $imageFolder && -w $imageFolder;
	
	# only run scanner if we want to show artist pictures and pre-cache or at least download pictures
	return unless $prefs->get('browseArtistPictures') && ( $precacheArtwork || $prefs->get('lookupArtistPictures') );
	
	$class->_scanArtistPhotos();
}

sub _scanArtistPhotos {
	my $class = shift;
	
	# Find distinct artists to check for artwork
	# unfortunately we can't just use an "artists" CLI query, as that code is not loaded in scanner mode
#	my $va  = $serverprefs->get('variousArtistAutoIdentification');
	my $sql = 'SELECT contributors.id, contributors.name FROM contributors ';
#	$sql   .= 'JOIN contributor_album ON contributor_album.contributor = contributors.id ';
#	$sql   .= 'JOIN albums ON contributor_album.album = albums.id ' if $va;
#	$sql   .= 'WHERE contributor_album.role IN (' . join( ',', @{Slim::Schema->artistOnlyRoles || []} ) . ') ';
#	$sql   .= 'AND (albums.compilation IS NULL OR albums.compilation = 0)' if $va;
#	$sql   .= "GROUP BY contributors.id";

	my $dbh = Slim::Schema->dbh;
	
	my ($count) = $dbh->selectrow_array( qq{
		SELECT COUNT(*) FROM ( $sql ) AS t1
	}) || 0;
	
	my $vaObj = Slim::Schema->variousArtistsObject;
	$count++ if $vaObj;
	
	my $sth = $dbh->prepare($sql);
	$sth->execute();

	my $progress = undef;

	if ($count) {
		$progress = Slim::Utils::Progress->new({ 
			'type'  => 'importer',
			'name'  => 'plugin_musicartistinfo_artistPhoto',
			'total' => $count,
			'bar'   => 1
		});
	}
	
	$ua = LWP::UserAgent->new(
		agent   => Slim::Utils::Misc::userAgentString(),
		timeout => 15,
	) if $prefs->get('lookupArtistPictures');

	$max = 500 unless $imageFolder;
	
	while ( _getArtistPhotoURL({
		sth      => $sth,
		count    => $count,
		progress => $progress,
		vaObj    => $vaObj ? {
			id => $vaObj->id,
			name => $vaObj->name,
		} : undef,
	}) ) {}
}


sub _getArtistPhotoURL {
	my $params = shift;

	my $progress = $params->{progress};

	# get next artist from db
	if ( my $artist = ($params->{sth}->fetchrow_hashref || $params->{vaObj}) ) {
		$artist->{name} = Slim::Utils::Unicode::utf8decode($artist->{name});

		$progress->update( $artist->{name} ) if $progress;
		time() > $i && ($i = time + 5) && Slim::Schema->forceCommit;
		
		main::DEBUGLOG && $log->debug("Getting artwork for " . $artist->{name});
		
		if ( my $file = Plugins::MusicArtistInfo::LocalArtwork->getArtistPhoto({
			artist_id => $artist->{id},
			artist    => $artist->{name},
			rawUrl    => 1,		# don't return the proxied URL, we want the raw file
			force     => 1,		# don't return cached value, this is a scan
		}) ) {
			_precacheArtistImage($artist, $file);
		}
		elsif ($ua) {		# only defined if $prefs->get('lookupArtistPictures')
			Plugins::MusicArtistInfo::LFM->getArtistPhoto(undef, sub {
				_precacheArtistImage($artist, @_);
			}, {
				artist => $artist->{name}
			});
		}

		return 1 if $artist != $params->{vaObj};
	}

	if ( $progress ) {
		$progress->final($params->{count});
		$log->error( "getArtistPhotoURL finished in " . $progress->duration );
	}

	Slim::Music::Import->endImporter('plugin_musicartistinfo_artistPhoto');
	
	return 0;
}

sub _precacheArtistImage {
	my ($artist, $img) = @_;
	
	return unless $precacheArtwork || $imageFolder;
	
	my $artist_id = $artist->{id};

	$specs         ||= join(',', Slim::Music::Artwork::getResizeSpecs());
	$testSpec      ||= (Slim::Music::Artwork::getResizeSpecs())[-1];
 	$cache         ||= Slim::Utils::Cache->new();
	$cachedir      ||= $serverprefs->get('cachedir');
	$imgProxyCache ||= Slim::Utils::DbArtworkCache->new(undef, 'imgproxy', '3M');	# expire in three months - IDs might change
	
	if ( $artist_id && ref $img eq 'HASH' && (my $url = $img->{url}) ) {

		$url =~ s/\/_\//\/$max\// if $max;
		
		main::DEBUGLOG && $log->debug("Getting $url to be pre-cached");
		
		my $file;
		
		# if user wants us to save a copy on the disk, write to our image folder instead
		if ($imageFolder) {
			$file = Plugins::MusicArtistInfo::Importer::filename($url, $imageFolder, $artist->{name});
		}
		else {
			$file = catdir( $cachedir, 'imgproxy_' . Digest::MD5::md5_hex($url) );
		}

		if (my $image = $cache->get("mai_$url")) {
			File::Slurp::write_file($file, $image);
		}
		else {
			my $response = $ua->get( $url, ':content_file' => $file );
			if ($response && $response->is_success) {
				$cache->set("mai_$url", scalar File::Slurp::read_file($file, binmode => ':raw'), 86400) unless $imageFolder;
			}
			else {
				$log->warn("Image download failed for $url: " . $response->message);
			}
		}
		
		return unless $precacheArtwork && -f $file;
		
		Slim::Utils::ImageResizer->resize($file, "imageproxy/mai/artist/$artist_id/image_", $specs, undef, $imgProxyCache );
		
		unlink $file unless $imageFolder;
	}
	elsif ( $precacheArtwork && $artist_id ) {
		$img ||= Plugins::MusicArtistInfo::LocalArtwork->defaultArtistPhoto();
		$img = Slim::Utils::Misc::pathFromFileURL($img) if $img =~ /^file/;
		
		return unless $img && -f $img;
		
		my $mtime = (stat(_))[9];

		# see whether the file has changed at all - otherwise return quickly
		if (my $cached = $imgProxyCache->get("imageproxy/mai/artist/$artist_id/image_$testSpec") ) {
			if ($cached->{original_path} eq $img && $cached->{mtime} == $mtime) {
				main::DEBUGLOG && $log->is_debug && $log->debug("Pre-cached image has not changed: $img");
				return;
			}
		}

		Slim::Utils::ImageResizer->resize($img, "imageproxy/mai/artist/$artist_id/image_", $specs, undef, $imgProxyCache );
	}
}

1;