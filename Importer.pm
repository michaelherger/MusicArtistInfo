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

use Plugins::MusicArtistInfo::Common;
use Plugins::MusicArtistInfo::Discogs;
use Plugins::MusicArtistInfo::LFM;
use Plugins::MusicArtistInfo::LocalArtwork;

use constant EXPIRY => 60 * 86400;

my $log = logger('plugin.musicartistinfo');
my $prefs = preferences('plugin.musicartistinfo');
my $serverprefs = preferences('server');

my $newTracks = [];
my ($ua, $cache, $cachedir, $imgProxyCache, $specs, $max, $precacheArtwork, $saveArtistPictures, $saveCoverArt, $imageFolder, $filenameTemplate);

sub initPlugin {
	my $class = shift;
	
	$precacheArtwork = $serverprefs->get('precacheArtwork');
	
	return unless $prefs->get('runImporter') && ($precacheArtwork || $prefs->get('lookupArtistPictures') || $prefs->get('lookupCoverArt'));

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

	$cachedir = $serverprefs->get('cachedir');

	$specs = join(',', Slim::Music::Artwork::getResizeSpecs());
		
	($max) = $specs =~ /(\d+)/;
	if ($max*1) {
		# 252 & 500 are known sizes for last.fm
		if    ($max <= 252) { $max = 252 }
		elsif ($max <= 500) { $max = 500 }
		else  { $max = 0 }
	}
	
	$class->_scanAlbumCovers();
	$class->_scanArtistPhotos();
}

sub _scanAlbumCovers {
	my $class = shift;
	
	# Find distinct albums to check for artwork.
	my $albums = Slim::Schema->search('Album', {
		'me.artwork' => { '='  => undef },
	});

	my $dbh = Slim::Schema->dbh;

	my $sth_update_tracks = $dbh->prepare( qq{
	    UPDATE tracks
	    SET    cover = ?, coverid = ?
	    WHERE  album = ?
	} );
	
	my $sth_update_albums = $dbh->prepare( qq{
		UPDATE albums
		SET    artwork = ?
		WHERE  id = ?
	} );
	
	my $progress = undef;
	my $count    = $albums->count;

	if ($count) {
		$progress = Slim::Utils::Progress->new({ 
			'type'  => 'importer',
			'name'  => 'plugin_musicartistinfo_albumCover',
			'total' => $count,
			'bar'   => 1
		});
	}
	
	$i = 0;
	
	$ua = LWP::UserAgent->new(
		agent   => Slim::Utils::Misc::userAgentString(),
		timeout => 15,
	) if $prefs->get('lookupCoverArt');
		
	$imageFolder = $serverprefs->get('artfolder');
	$filenameTemplate = $serverprefs->get('coverArt') || 'ARTIST - ALBUM';
	$filenameTemplate =~ s/^%//;

	if ( $saveCoverArt = $prefs->get('saveCoverArt') ) {
		$saveCoverArt = undef unless $imageFolder && -d $imageFolder && -w $imageFolder;
	}

	$max = 0 if $saveCoverArt;
	
	while ( _getAlbumCoverURL({
		albums   => $albums,
		count    => $count,
		progress => $progress,
		sth_update_tracks => $sth_update_tracks,
		sth_update_albums => $sth_update_albums,
	}) ) {}
}

sub _getAlbumCoverURL {
	my $params = shift;

	my $progress = $params->{progress};

	# get next track from db
	if ( my $album = $params->{albums}->next ) {
		
		my $albumname = $album->name;
		my $albumid   = $album->id;
		my $artist    = $album->contributor ? $album->contributor->name : '';
		
		$progress->update( "$artist - $albumname" ) if $progress;
		$i++ % 5 == 0 && Slim::Schema->forceCommit;
		
		# Only lookup albums that have artist names
		if ($artist && $albumname) {
			my $albumname2 = Plugins::MusicArtistInfo::Common::cleanupAlbumName($albumname);
			my $args = {
				album  => $albumname2,
				artist => $artist,
			};
			
			$params->{albumid} = $albumid;
			
			my @filenames;
			
			my $filename1 = $filenameTemplate;
			$filename1 =~ s/ARTIST/$artist/;
			$filename1 =~ s/ALBUM/$albumname2/;
			push @filenames, "\Q$filename1\E";

			$filename1 = $filenameTemplate;
			$filename1 =~ s/ARTIST/$artist/;
			$filename1 =~ s/ALBUM/$albumname/;
			push @filenames, "\Q$filename1\E";

			$filename1 = $filenameTemplate;
			$albumname2 = Slim::Utils::Text::ignorePunct($albumname);
			my $artist2 = Slim::Utils::Text::ignorePunct($artist);
			$filename1 =~ s/ARTIST/$artist2/;
			$filename1 =~ s/ALBUM/$albumname2/;
			push @filenames, "\Q$filename1\E";

			$filename1 = $filenameTemplate;
			$albumname2 = Slim::Utils::Text::ignorePunct($albumname2);
			$filename1 =~ s/ARTIST/$artist2/;
			$filename1 =~ s/ALBUM/$albumname2/;
			push @filenames, "\Q$filename1\E";

			if ( my $file = Plugins::MusicArtistInfo::Common::imageInFolder($imageFolder, '(?:' . join('|', @filenames) . ')') ) {
				_precacheAlbumCover($artist, $albumname, $file, $params);
			}
			elsif ($ua) {
				Plugins::MusicArtistInfo::Discogs->getAlbumCover(undef, sub {
					my $albumInfo = shift;
					
					if ($albumInfo->{url}) {
						_precacheAlbumCover($artist, $albumname, $albumInfo->{url}, $params);
					}
					else {
						Plugins::MusicArtistInfo::LFM->getAlbumCover(undef, sub {
							my $albumInfo = shift;
							
							if ($albumInfo->{url}) {
								_precacheAlbumCover($artist, $albumname, $albumInfo->{url}, $params);
							}
							else {
								# nothing to do?
								$log->warn("No cover found for: $artist - $albumname");
							}
						}, $args);
					}
				}, $args);
			}
		}

		return 1;
	}

	if ( $progress ) {
		$progress->final($params->{count}) ;
		$log->error( "getAlbumCoverURL finished in " . $progress->duration );
	}

	Slim::Music::Import->endImporter('plugin_musicartistinfo_albumCover');
	
	return 0;
}

sub _precacheAlbumCover {
	my ($artist, $album, $url, $params) = @_;
	
	if ( $artist && $album && $url ) {
		main::DEBUGLOG && $log->debug("Getting $url to be pre-cached");

		# XXX - use correct setting for placeholders!
		my $file = File::Spec::Functions::catdir( $imageFolder, Slim::Utils::Text::ignorePunct($artist) . ' - ' . Slim::Utils::Text::ignorePunct($album) );
		my ($ext) = $url =~ /\.(png|jpe?g|gif)/i;
		$ext =~ s/jpeg/jpg/;
		$file .= ".$ext";
		
		my $tmpFile = File::Spec::Functions::catdir( $cachedir, 'imgproxy_' . Digest::MD5::md5_hex($url) );
		
		if ($url =~ /^http:/) {
			$file = $tmpFile unless $saveCoverArt;
			my $response = $ua->get( $url, ':content_file' => $file );
			if ( !($response && $response->is_success && -e $file) ) {
				$file = undef;
				$log->warn("Image download failed for $url: " . $response->message) if $url =~ /^http:/;
			}
		}

		if ($file && -e $file) {
			my $progress  = $params->{progress};
			my $albumid   = $params->{albumid};
			
			my $coverid = Slim::Schema::Track->generateCoverId({
				cover => $file,
				url   => $file,,
			});
			
			$params->{sth_update_tracks}->execute( $file, $coverid, $albumid );
			$params->{sth_update_albums}->execute( $coverid, $albumid );
			
			unlink $file unless $saveCoverArt;
		}
	}
}

sub _scanArtistPhotos {
	my $class = shift;
	
	# Find distinct artists to check for artwork
	# unfortunately we can't just use an "artists" CLI query, as that code is not loaded in scanner mode
	my $va  = $serverprefs->get('variousArtistAutoIdentification');
	my $sql = 'SELECT contributors.id, contributors.name FROM contributors ';
	$sql   .= 'JOIN contributor_album ON contributor_album.contributor = contributors.id ';
	$sql   .= 'JOIN albums ON contributor_album.album = albums.id ' if $va;
	$sql   .= 'WHERE contributor_album.role IN (' . join( ',', @{Slim::Schema->artistOnlyRoles || []} ) . ') ';
	$sql   .= 'AND (albums.compilation IS NULL OR albums.compilation = 0)' if $va;
	$sql   .= "GROUP BY contributors.id";

	my $dbh = Slim::Schema->dbh;
	
	my ($count) = $dbh->selectrow_array( qq{
		SELECT COUNT(*) FROM ( $sql ) AS t1
	}) || 0;
	
	my $sth = $dbh->prepare_cached($sql);
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

	$i = 0;
	
	$ua = $prefs->get('lookupArtistPictures') ? LWP::UserAgent->new(
		agent   => Slim::Utils::Misc::userAgentString(),
		timeout => 15,
	) : undef;
		
 	$imgProxyCache = Slim::Utils::DbArtworkCache->new(undef, 'imgproxy', time() + EXPIRY);
 	$cache         = Slim::Utils::Cache->new();
	$imageFolder   = $prefs->get('artistImageFolder');

	if ( $saveArtistPictures = $prefs->get('saveArtistPictures') ) {
		$imageFolder = $prefs->get('artistImageFolder');
		$saveArtistPictures = undef unless $imageFolder && -d $imageFolder && -w $imageFolder;
	}

	$max = 0 if $saveArtistPictures;
	
	while ( _getArtistPhotoURL({
		sth      => $sth,
		count    => $count,
		progress => $progress,
	}) ) {}
	
	$imgProxyCache->{default_expires_in} = 86400 * 30;
}


sub _getArtistPhotoURL {
	my $params = shift;

	my $progress = $params->{progress};

	# get next artist from db
	if ( my $artist = $params->{sth}->fetchrow_hashref ) {
		$progress->update( $artist->{name} ) if $progress;
		$i++ % 5 == 0 && Slim::Schema->forceCommit;
		
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

		return 1;
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
	
	return unless $precacheArtwork || $saveArtistPictures;
	
	my $artist_id = $artist->{id};
	
	if ( $artist_id && ref $img eq 'HASH' && (my $url = $img->{url}) ) {
		if ( !$saveArtistPictures && !$max && (($img->{width} && $img->{width} > 1500) || ($img->{height} && $img->{height} > 1500)) ) {
			main::INFOLOG && $log->is_info && $log->info("Full size image is huge - try smaller copy instead (500px)\n" . Data::Dump::dump($img));
			$max = 500;
		}

		$url =~ s/\/_\//\/$max\// if $max && !$saveArtistPictures;
		
		main::DEBUGLOG && $log->debug("Getting $url to be pre-cached");
		
		my $tmpFile;
		
		# if user wants us to save a copy on the disk, write to our image folder instead
		if ($saveArtistPictures) {
			$tmpFile = File::Spec::Functions::catdir( $imageFolder, Slim::Utils::Text::ignorePunct($artist->{name}) );
			my ($ext) = $url =~ /\.(png|jpe?g|gif)/i;
			$tmpFile .= ".$ext";
		}
		else {
			 $tmpFile = File::Spec::Functions::catdir( $cachedir, 'imgproxy_' . Digest::MD5::md5_hex($url) );
		}

		if (my $image = $cache->get("mai_$url")) {
			File::Slurp::write_file($tmpFile, $image);
		}
		else {
			my $response = $ua->get( $url, ':content_file' => $tmpFile );
			if ($response && $response->is_success) {
				$cache->set("mai_$url", scalar File::Slurp::read_file($tmpFile, binmode => ':raw')) unless $saveArtistPictures;
			}
			else {
				$log->warn("Image download failed for $url: " . $response->message);
			}
		}
		
		return unless $precacheArtwork && -f $tmpFile;
		
		# use distributed expiry to not have to update everything at the same time
		$imgProxyCache->{default_expires_in} = time() + int(rand(EXPIRY));

		Slim::Utils::ImageResizer->resize($tmpFile, "imageproxy/mai/artist/$artist_id/image_", $specs, undef, $imgProxyCache );
		
		unlink $tmpFile unless $saveArtistPictures;
	}
	elsif ( $precacheArtwork && $artist_id && $img ) {
		$img = Slim::Utils::Misc::pathFromFileURL($img) if $img =~ /^file/;
		Slim::Utils::ImageResizer->resize($img, "imageproxy/mai/artist/$artist_id/image_", $specs, undef, $imgProxyCache ) if -f $img;
	}
}

1;