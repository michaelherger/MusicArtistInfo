package Plugins::MusicArtistInfo::Importer;

# this is a helper class to only load the actual importer if LMS is compatible

use strict;
use constant CAN_IMAGEPROXY => (Slim::Utils::Versions->compareVersions($::VERSION, '7.8.0') >= 0);
use Digest::MD5;
use File::Spec::Functions qw(catdir);
use LWP::UserAgent;

use Slim::Music::Import;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::MusicArtistInfo::Common;
use Plugins::MusicArtistInfo::Discogs;
use Plugins::MusicArtistInfo::LFM;
use Plugins::MusicArtistInfo::LocalArtwork;

my ($i, $ua, $imageFolder, $filenameTemplate, $saveCoverArt, $max, $cachedir);

my $log = logger('plugin.musicartistinfo');
my $prefs = preferences('plugin.musicartistinfo');
my $serverprefs = preferences('server');

sub initPlugin {
	my $class = shift;
	
	return unless $prefs->get('runImporter') && ($serverprefs->get('precacheArtwork') || $prefs->get('lookupArtistPictures') || $prefs->get('lookupCoverArt'));

	Slim::Music::Import->addImporter($class, {
		'type'         => 'post',
		'weight'       => 85,
		'use'          => 1,
	});
	
	return 1;
}

sub startScan { 
	my $class = shift;

	$class->_scanAlbumCovers();

	if (CAN_IMAGEPROXY) {
		require Plugins::MusicArtistInfo::Importer2;
		return Plugins::MusicArtistInfo::Importer2->startScan(@_);
	}
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
	
	my ($progress, $count);

	if ($count = $albums->count) {
		$progress = Slim::Utils::Progress->new({ 
			'type'  => 'importer',
			'name'  => 'plugin_musicartistinfo_albumCover',
			'total' => $count,
			'bar'   => 1
		});
	}
	
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

	$max = 500 unless $saveCoverArt;
	
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
		time() > $i && ($i = time + 5) && Slim::Schema->forceCommit;
		
		# Only lookup albums that have artist names
		if ($artist && $albumname) {
			my $albumname2 = Plugins::MusicArtistInfo::Common::cleanupAlbumName($albumname);
			my $args = {
				album  => $albumname2,
				artist => $artist,
			};
			
			$params->{albumid} = $albumid;
			
			my $replacer = sub {
				my ($artist, $album) = @_;
				my $filename = $filenameTemplate;
				$filename =~ s/ARTIST/$artist/;
				$filename =~ s/ALBUM/$album/;
				return $filename;
			};

			my @filenames = (
				$replacer->($artist, $albumname2),
				$replacer->($artist, $albumname),
				$replacer->(Slim::Utils::Text::ignorePunct($artist), Slim::Utils::Text::ignorePunct($albumname)),
				$replacer->(Slim::Utils::Text::ignorePunct($artist), Slim::Utils::Text::ignorePunct($albumname2)),
			);

			if ( my $file = Plugins::MusicArtistInfo::Common::imageInFolder($imageFolder, @filenames) ) {
				_setAlbumCover($artist, $albumname, $file, $params);
			}
			elsif ($ua) {
				Plugins::MusicArtistInfo::Discogs->getAlbumCover(undef, sub {
					my $albumInfo = shift;
					
					if ($albumInfo->{url}) {
						_setAlbumCover($artist, $albumname, $albumInfo->{url}, $params);
					}
					else {
						Plugins::MusicArtistInfo::LFM->getAlbumCover(undef, sub {
							my $albumInfo = shift;
							
							if ($albumInfo->{url}) {
								_setAlbumCover($artist, $albumname, $albumInfo->{url}, $params);
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

sub _setAlbumCover {
	my ($artist, $album, $url, $params) = @_;
	
	if ( $artist && $album && $url ) {
		$cachedir ||= $serverprefs->get('cachedir');
	
		$url =~ s/\/_\//\/$max\// if $max && !$saveCoverArt;
		
		main::DEBUGLOG && $log->debug("Getting $url to be pre-cached");

		# XXX - use correct setting for placeholders!
		my $file = catdir( $imageFolder, Slim::Utils::Text::ignorePunct($artist) . ' - ' . Slim::Utils::Text::ignorePunct($album) );
		my ($ext) = $url =~ /\.(png|jpe?g|gif)/i;
		$ext =~ s/jpeg/jpg/;
		$file .= ".$ext";
		
		my $tmpFile = catdir( $cachedir, 'imgproxy_' . Digest::MD5::md5_hex($url) );
		
		if ($url =~ /^http:/) {
			$file = $tmpFile unless $saveCoverArt;
			my $response = $ua->get( $url, ':content_file' => $file );
			if ( !($response && $response->is_success && -e $file) ) {
				$file = undef;
				$log->warn("Image download failed for $url: " . $response->message) if $url =~ /^http:/;
			}
		}

		if ($file && -e $file) {
			my $albumid = $params->{albumid};
			
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

1;