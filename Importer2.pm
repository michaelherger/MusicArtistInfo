package Plugins::MusicArtistInfo::Importer2;

use strict;
use Digest::MD5;
use File::Spec::Functions qw(catdir);
use File::Slurp;
use Tie::RegexpHash;
use URI::Escape;

use Slim::Music::Import;
use Slim::Utils::ArtworkCache;
use Slim::Utils::Cache;
use Slim::Utils::ImageResizer;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::MusicArtistInfo::Common qw(CAN_LMS_ARTIST_ARTWORK CAN_ONLINE_LIBRARY);
use Plugins::MusicArtistInfo::API;
use Plugins::MusicArtistInfo::LocalArtwork;

use constant MAX_IMAGE_SIZE => 3072 * 3072;
use constant IS_ONLINE_LIBRARY_SCAN => main::SCANNER && $ARGV[-1] && $ARGV[-1] eq 'onlinelibrary' ? 1 : 0;

# this holds pointers to functions handling a given artist external ID
my %artistPictureImporterHandlers = ();
tie %artistPictureImporterHandlers, 'Tie::RegexpHash';

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.musicartistinfo');
my $prefs = preferences('plugin.musicartistinfo');
my $serverprefs = preferences('server');

my ($i, $ua, $cachedir, $imgProxyCache, $specs, $testSpec, $max, $precacheArtwork, $imageFolder, $isWipeDb, $saveMissingArtistPicturePlaceholder);

sub startScan {
	my $class = shift;

	Plugins::MusicArtistInfo::Importer->_initCacheFolder(_cacheFolder(), $prefs->get('artistImageFolder'));

	if (CAN_ONLINE_LIBRARY && !scalar keys %artistPictureImporterHandlers) {
		foreach my $importerClass (Slim::Utils::PluginManager->enabledPlugins) {
			eval {
				if ($importerClass->can('getArtistPicture')) {
					my ($prefix) = $importerClass =~ /([^:]*?)::Importer/;
					$prefix = lc($prefix);
					$prefix = 'spotify' if $prefix eq 'spotty';
					my $regex = "^${prefix}:";

					$artistPictureImporterHandlers{qr/$regex/} = $importerClass;
				}
			};
		}
	}

	$isWipeDb = Slim::Music::Import->stillScanning() eq 'SETUP_WIPEDB';

	$precacheArtwork = $serverprefs->get('precacheArtwork');
	$saveMissingArtistPicturePlaceholder = $prefs->get('saveMissingArtistPicturePlaceholder') || 0;

	$imageFolder = $prefs->get('artistImageFolder');
	if ( !($imageFolder && -d $imageFolder && -w _) ) {
		$imageFolder && $log->error('Artist Image Folder either does not exist or is not writable: ' . $imageFolder);
		$imageFolder = _cacheFolder();
		# if user doesn't care about artwork folder, then he doesn't care about artwork. Only download smaller size.
		$max = 500;
	}

	if (main::SCANNER && !$serverprefs->get('artfolder')) {
		# in scanner mode prefs are read-only - we can temporarily overwrite it for the artist picture scan to pick up the right folder
		$serverprefs->set('artfolder', $imageFolder);
	}

	# only run scanner if we want to show artist pictures and pre-cache or at least download pictures
	return unless $prefs->get('browseArtistPictures') && ( $precacheArtwork || $prefs->get('lookupArtistPictures') );

	$class->_scanArtistPhotos();
}

sub _scanArtistPhotos {
	my $class = shift;

	# Find distinct artists to check for artwork
	# unfortunately we can't just use an "artists" CLI query, as that code is not loaded in scanner mode
	my $sql = sprintf('SELECT contributors.id, contributors.musicbrainz_id, contributors.name %s FROM contributors ', CAN_ONLINE_LIBRARY ? ', contributors.extid' : '');
	my (@where, $group);

	if (CAN_LMS_ARTIST_ARTWORK) {
		# during a rescan with LMS 9.1 we might already have a picture for an artist
		push @where, '(contributors.portrait IS NULL OR contributors.portrait = "")';
	}

	my %roles = map { $_ => 1 } @{
		Slim::Schema::Contributor->can('activeContributorRoles')
			? [ map { Slim::Schema::Contributor->typeToRole($_) } Slim::Schema::Contributor->activeContributorRoles() ]
			: Slim::Schema->artistOnlyRoles()
	};

	if ($prefs->get('lookupAlbumArtistPicturesOnly')) {
		$sql =~ s/ (FROM contributors )/, GROUP_CONCAT(contributor_album.role) AS roles $1/;

		my $va  = $serverprefs->get('variousArtistAutoIdentification');
		$sql   .= 'LEFT JOIN contributor_album ON contributor_album.contributor = contributors.id ';
		$sql   .= 'LEFT JOIN albums ON contributor_album.album = albums.id ' if $va;
		push @where, '(albums.compilation IS NULL OR albums.compilation = 0)' if $va;
		push @where, 'contributors.extid IS NOT NULL AND contributors.extid != ""' if IS_ONLINE_LIBRARY_SCAN;
		$group .= 'GROUP BY contributors.id';
	}
	elsif (IS_ONLINE_LIBRARY_SCAN) {
		push @where, 'contributors.extid IS NOT NULL';
	}

	$sql .= 'WHERE ' . join(' AND ', @where) if @where;
	$sql .= " $group";

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

	$ua = Plugins::MusicArtistInfo::Common->getUA() if $prefs->get('lookupArtistPictures');

	while ( _getArtistPhotoURL({
		sth      => $sth,
		count    => $count,
		roles    => \%roles,
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

		main::INFOLOG && $log->is_info && $log->info("Getting artwork for " . $artist->{name});

		my $artist_id = $artist->{id};
		my $idMatchKey = 'mai_id_map_' . lc(Slim::Utils::Text::ignoreCaseArticles($artist->{name}, 1));

		$imgProxyCache ||= Slim::Utils::DbArtworkCache->new(undef, 'imgproxy', time() + 86400 * 90);	# expire in three months - IDs might change

		if (!CAN_LMS_ARTIST_ARTWORK) {
			$testSpec ||= (Slim::Music::Artwork::getResizeSpecs())[-1];

			# we need to manually remove stale cache entries - or they'll stick around for weeks, blowing up the image proxy cache
			if ($isWipeDb && (my $cachedId = $cache->get($idMatchKey))) {
				foreach (Slim::Music::Artwork::getResizeSpecs()) {
					$imgProxyCache->remove("imageproxy/mai/artist/$cachedId/image_$_");
				}
			}
		}

		my $done = 0;

		# online only scan - no need to update if cached image exists
		if (IS_ONLINE_LIBRARY_SCAN && !CAN_LMS_ARTIST_ARTWORK && $imgProxyCache->get("imageproxy/mai/artist/$artist_id/image_$testSpec") ) {
			main::INFOLOG && $log->is_info && $log->info('Pre-cached image already exists for ' . $artist->{name});
			$done++;
		}
		# always look up local file updates
		elsif ( my $file = Plugins::MusicArtistInfo::LocalArtwork->getArtistPhoto({
			artist_id => $artist_id,
			artist    => $artist->{name},
			rawUrl    => 1,		# don't return the proxied URL, we want the raw file
			force     => 1,		# don't return cached value, this is a scan
		}) ) {
			_precacheArtistImage($artist, $file);
			$done++;
		}

		# cut short if rescanning and new artist ID is the same as the old one
		if (!$done && !$isWipeDb && (my $cachedId = $cache->get($idMatchKey))) {
			$done = $cachedId == $artist_id;
		}

		# only look up artwork for contributors with the desired roles
		if (!$done && $artist->{roles} && $params->{roles} && ref $params->{roles} eq 'HASH' && scalar keys %{$params->{roles}} ) {
			$done = !(grep { $params->{roles}->{$_} } split(',', $artist->{roles} || ''));
			if ($done && $saveMissingArtistPicturePlaceholder == 2) {
				_precacheArtistImage({ name => $artist->{name} }, undef);	# put in missing placeholder if desired
			}
		}

		if (CAN_ONLINE_LIBRARY && !$done && $ua && (my $url = _getImageUrlFromService($artist))) {
			_precacheArtistImage($artist, {
				url => $url
			});
			$done++;
		}
		elsif (!$done && $ua) {		# only defined if $prefs->get('lookupArtistPictures')
			Plugins::MusicArtistInfo::API->getArtistPhoto(sub {
				_precacheArtistImage($artist, @_);
			}, {
				artist => $artist->{name},
				mbid   => $artist->{musicbrainz_id},
			});
			$done++;
		}
		elsif (!$done && $saveMissingArtistPicturePlaceholder == 2) {
			_precacheArtistImage({ name => $artist->{name} }, undef);	# put in missing placeholder if desired
		}

		$cache->set($idMatchKey, $artist_id, '1y');
		return 1 if $artist != $params->{vaObj};
	}

	if ( $progress ) {
		$progress->final($params->{count});
		$log->error(sprintf('finished in %.3f seconds (%i artists)', $progress->duration, $params->{count}) );
	}

	return 0;
}

sub _getImageUrlFromService {
	my ($artist) = @_;

	my $extid = $artist->{extid} || return;

	if (my $serviceHandler = $artistPictureImporterHandlers{$extid}) {
		return $serviceHandler->getArtistPicture($extid);
	}
}

sub _precacheArtistImage {
	my ($artist, $img) = @_;

	return unless $precacheArtwork || $imageFolder;

	my $artist_id = $artist->{id};

	$specs    ||= join(',', Slim::Music::Artwork::getResizeSpecs());
	$cachedir ||= $serverprefs->get('cachedir');

	if ( $imageFolder && !($artist_id && $img) && $saveMissingArtistPicturePlaceholder ) {
		my $file = Plugins::MusicArtistInfo::Importer::filename('', $imageFolder, $artist->{name});
		$file =~ s/\.$/\.missing/;
		if (!-f $file) {
			main::INFOLOG && $log->is_info && $log->info("Putting placeholder file '$file'");
			File::Slurp::write_file($file, { err_mode => 'carp' }, '');
		}
	}

	return unless $artist_id;

	if ( ref $img eq 'HASH' && (my $url = $img->{url}) ) {

		$url =~ s/\/_\//\/$max\// if $max;

		main::INFOLOG && $log->is_info && $log->info("Getting $url to be pre-cached");

		my $file;

		# if user wants us to save a copy on the disk, write to our image folder instead
		if ($imageFolder) {
			$file = Plugins::MusicArtistInfo::Importer::filename($url, $imageFolder, $artist->{name});
		}
		else {
			$file = catdir( $cachedir, 'imgproxy_' . Digest::MD5::md5_hex($url) );
		}

		if (my $cached = $imgProxyCache->get($url)) {
			File::Slurp::write_file($file, { err_mode => 'carp' }, $cached->{data_ref});
		}
		elsif ($imageFolder && -f $file) {
			# if the file already exists, we don't need to download it again
			main::INFOLOG && $log->is_info && $log->info("File already exists: $file");
		}
		else {
			my $response = $ua->get( $url, ':content_file' => $file );

			if ($response && $response->is_success) {
				my ($ct) = $response->headers->content_type =~ /image\/(png|jpe?g)/;
				$ct =~ s/jpeg/jpg/;

				# some music services don't provide an extension - create it from the content type
				if ($file !~ /\.(?:jpe?g|gif|png)$/) {
					my $newName = $file . ($file =~ /\.$/ ? '' : '.') . $ct;
					rename $file, $newName;
					$file = $newName;
				}

				if (!$imageFolder) {
					my $imageRef = File::Slurp::read_file($file, binmode => ':raw', scalar_ref => 1);
					$imgProxyCache->set($url, {
						content_type  => $ct,
						mtime         => 0,
						original_path => undef,
						data_ref      => $imageRef,
					});
				}
			}
			else {
				$log->warn("Image download failed for $url: " . $response->message);
			}
		}

		return if CAN_LMS_ARTIST_ARTWORK;
		return unless $precacheArtwork && -f $file;

		Slim::Utils::ImageResizer->resize($file, "imageproxy/mai/artist/$artist_id/image_", $specs, undef, $imgProxyCache );

		$file =~ s/\.(?:jpe?g|gif|png)$/\.missing/i if $imageFolder;
		unlink $file;
	}
	elsif ( !CAN_LMS_ARTIST_ARTWORK && $precacheArtwork ) {
		$img ||= Plugins::MusicArtistInfo::LocalArtwork->defaultArtistPhoto();
		$img = Slim::Utils::Misc::pathFromFileURL($img) if Slim::Music::Info::isFileURL($img);

		return unless $img && -f $img;

		my $mtime = (stat(_))[9];

		# see whether the file has changed at all - otherwise return quickly
		if (my $cached = $imgProxyCache->get("imageproxy/mai/artist/$artist_id/image_$testSpec") ) {
			if ($cached->{original_path} eq $img && $cached->{mtime} == $mtime) {
				main::INFOLOG && $log->is_info && $log->info("Pre-cached image has not changed: $img");
				return;
			}
		}

		Slim::Utils::ImageResizer->resize($img, "imageproxy/mai/artist/$artist_id/image_", $specs, undef, $imgProxyCache );
	}
}

sub _cacheFolder {
	catdir($serverprefs->get('cachedir'), 'mai_portraits');
}

1;