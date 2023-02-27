package Plugins::MusicArtistInfo::Importer;

# this is a helper class to only load the actual importer if LMS is compatible

use strict;

use Digest::MD5;
use File::Spec::Functions qw(catdir);

use Slim::Music::Import;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::MusicArtistInfo::Common qw(CAN_ONLINE_LIBRARY CAN_IMAGEPROXY);
use Plugins::MusicArtistInfo::LFM;

use constant GENRE_REPLACE_ID => ['spotify', 'wimp'];

my ($i, $ua, $imageFolder, $filenameTemplate, $max, $cachedir);

my $log = logger('plugin.musicartistinfo');
my $prefs = preferences('plugin.musicartistinfo');
my $serverprefs = preferences('server');

sub initPlugin {
	my $class = shift;

	return unless $prefs->get('runImporter') && ($serverprefs->get('precacheArtwork') || $prefs->get('lookupArtistPictures') || $prefs->get('lookupCoverArt') || $prefs->get('replaceOnlineGenres'));

	Slim::Music::Import->addImporter($class, {
		'type'         => 'post',
		'weight'       => 85,
		'use'          => 1,
	});

	$class->_initCacheFolder();

	return 1;
}

sub startScan {
	my $class = shift;

	$class->_scanAlbumCovers();
	$class->_scanAlbumGenre() if CAN_ONLINE_LIBRARY && $prefs->get('replaceOnlineGenres');

	if (CAN_IMAGEPROXY && $prefs->get('lookupArtistPictures')) {
		require Plugins::MusicArtistInfo::Importer2;
		Plugins::MusicArtistInfo::Importer2->startScan(@_);
	}

	Slim::Music::Import->endImporter($class);
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

	$ua = Plugins::MusicArtistInfo::Common->getUA() if $prefs->get('lookupCoverArt');

	$imageFolder = $serverprefs->get('artfolder');

	# use our own folder in the cache folder if the user has not defined an artfolder
	if ( !($imageFolder && -d $imageFolder && -w _) ) {
		$max = 500;		# if user doesn't care about artwork folder, then he doesn't care about artwork. Only download smaller size.
		$imageFolder = $class->_cacheFolder;
	}

	$filenameTemplate = $serverprefs->get('coverArt') || 'ARTIST - ALBUM';
	# we can't handle wildcards, as all artwork will be in the same folder
	$filenameTemplate = 'ARTIST - ALBUM' if $filenameTemplate =~ /\*/;
	$filenameTemplate =~ s/^%//;

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

		my $albumname = Slim::Utils::Unicode::utf8decode($album->name);
		my $albumid   = $album->id;
		my $artist    = $album->contributor ? Slim::Utils::Unicode::utf8decode($album->contributor->name) : '';

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
				$replacer->($artist, $albumname),
				$replacer->($artist, $albumname2),
				$replacer->(Slim::Utils::Text::ignorePunct($artist), Slim::Utils::Text::ignorePunct($albumname)),
				$replacer->(Slim::Utils::Text::ignorePunct($artist), Slim::Utils::Text::ignorePunct($albumname2)),
			);

			if ($album->compilation) {
				push @filenames,
					$replacer->('Various Artists', $albumname),
					$replacer->('Various Artists', $albumname2),
					$replacer->('Various Artists', Slim::Utils::Text::ignorePunct($albumname)),
					$replacer->('Various Artists', Slim::Utils::Text::ignorePunct($albumname2));
			}

			if ( my $file = Plugins::MusicArtistInfo::Common::imageInFolder($imageFolder, @filenames) ) {
				_setAlbumCover($artist, $albumname, $file, $params);
			}
			elsif ($ua) {
				Plugins::MusicArtistInfo::LFM->getAlbumCover(undef, sub {
					my $albumInfo = shift;

					if ($albumInfo->{url}) {
						_setAlbumCover($artist, $albumname, $albumInfo->{url}, $params);
					}
					else {
						# another try if this is a compilation album
						if ($album->compilation) {
							$args->{artist} = 'Various Artists';
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
						else {
							# nothing to do?
							$log->warn("No cover found for: $artist - $albumname");
						}
					}
				}, $args);
			}
		}

		return 1;
	}

	if ($progress) {
		$progress->final($params->{count}) ;
		$log->error(sprintf('  finished in %.3f seconds', $progress->duration));
	}

	return 0;
}

sub _setAlbumCover {
	my ($artist, $album, $url, $params) = @_;

	if ( $artist && $album && $url ) {
		$cachedir ||= $serverprefs->get('cachedir');

		$url =~ s/\/_\//\/$max\// if $max;

		main::DEBUGLOG && $log->debug("Getting $url to be pre-cached");

		my $file = filename($url, $imageFolder, $artist, $album);

		if ($url =~ /^https:/) {
			my $response = $ua->get( $url, ':content_file' => $file );
			if ( !($response && $response->is_success && -e $file) ) {
				$file = undef;
				$log->warn("Image download failed for $url: " . $response->message);
			}
		}

		if ($file && -e $file) {
			my $albumid = $params->{albumid};

			my $track;

			if ( my $albumObj = Slim::Schema->find('Album', $albumid) ) {
				$track = $albumObj->tracks->first;
			}

			my $coverid = Slim::Schema::Track->generateCoverId({
				cover => $file,
				url   => ($track ? $track->url : undef) || $file,
			});

			$params->{sth_update_tracks}->execute( $file, $coverid, $albumid );
			$params->{sth_update_albums}->execute( $coverid, $albumid );
		}
	}
}

sub _scanAlbumGenre { if (CAN_ONLINE_LIBRARY) {
	my $class = shift;

	require Plugins::MusicArtistInfo::AllMusic::Sync;

	my $extIdCondition = join(' OR ', map {
		"albums.extid LIKE '$_%'";
	} @{GENRE_REPLACE_ID()});

	my $dbh = Slim::Schema->dbh or return;
	my $sth = $dbh->prepare_cached("SELECT COUNT(1) FROM albums WHERE $extIdCondition;");
	$sth->execute();
	my ($count) = $sth->fetchrow_array;
	$sth->finish;

	my $progress = Slim::Utils::Progress->new({
		'type'  => 'importer',
		'name'  => 'plugin_musicartistinfo_genre_replacement',
		'total' => $count,
		'bar'   => 1,
	});

	my $sql = qq(SELECT albums.id, albums.title, contributors.name
					FROM albums JOIN contributors ON contributors.id = albums.contributor
					WHERE $extIdCondition;);

	my ($albumId, $title, $name);

	$sth = $dbh->prepare_cached($sql);
	$sth->execute();
	$sth->bind_columns(\$albumId, \$title, \$name);

	my $mappings = {};
	my $selectSQL = q(SELECT tracks.id
							FROM tracks
							WHERE tracks.album = ? AND tracks.extid IS NOT NULL;);

	my $trackId;
	my $tracks_sth = $dbh->prepare_cached($selectSQL);
	$tracks_sth->bind_columns(\$trackId);

	while ( $sth->fetch ) {
		utf8::decode($title);
		utf8::decode($name);

		$progress->update(sprintf('%s - %s', $title, $name));
		Slim::Schema->forceCommit;

		my $albumInfo = Plugins::MusicArtistInfo::AllMusic::Sync->getAlbumInfo({
			artist => $name,
			album  => $title
		}) || {};

		if (my $genreName = $albumInfo->{genres}) {
			$tracks_sth->execute($albumId);

			while ($tracks_sth->fetch) {
				foreach (split /,\s*/, $genreName) {
					Slim::Schema::Genre->add($_, $trackId + 0);
				}
			}
		}
	}

	if ($progress) {
		$progress->final($count) ;
		$log->error(sprintf('    finished in %.3f seconds', $progress->duration));
	}

	Slim::Schema->forceCommit;
} }

sub filename {
	my ($url, $folder, $artist, $album) = @_;

	$artist = Slim::Utils::Misc::cleanupFilename(
		Slim::Utils::Unicode::encode_locale(
			Slim::Utils::Text::ignorePunct($artist)
		)
	);

	$album ||= '';
	$album = ' - ' . Slim::Utils::Misc::cleanupFilename(
		Slim::Utils::Unicode::encode_locale(
			Slim::Utils::Text::ignorePunct($album)
		)
	) if $album;

	# XXX - use correct setting for placeholders!
	my $file = catdir( $folder, $artist . $album );
	my ($ext) = $url =~ /\.(png|jpe?g|gif)/i;
	$ext =~ s/jpeg/jpg/;

	return "$file.$ext";
}

sub _initCacheFolder {
	# purge cached files
	$imageFolder = $serverprefs->get('artfolder');

	my $useCustomFolder = $imageFolder && -d $imageFolder && -w _;
	require File::Copy if $useCustomFolder;

	my $cacheDir = _cacheFolder();
	mkdir $cacheDir unless -d $cacheDir;

	opendir my ($dirh), $cacheDir;

	# cleanup of temporary coverart folder
	if ($dirh) {
		for ( readdir $dirh ) {
			my $file = catdir($cacheDir, $_);

			next unless -f $file && -w _;

			# remove old files - let them be re-downloaded every now and then
			if (-M _ > 60 + rand(15)) {
				unlink $file or logError("Unable to remove file: $file: $!");
			}
			elsif ($useCustomFolder) {
				my $target = catdir($imageFolder, $_);
				# move files from temporary cache folder to user's artfolder (if possible)
				File::Copy::move($file, $target) unless -f $target;
			}
		}

		closedir $dirh;
	}
}

sub _cacheFolder {
	catdir($serverprefs->get('cachedir'), 'mai_coverart');
}

1;