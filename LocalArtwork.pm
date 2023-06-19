package Plugins::MusicArtistInfo::LocalArtwork;

use strict;
use File::Basename qw(dirname basename);
use File::Next;
use File::Spec::Functions qw(catdir catfile);
use Digest::MD5 qw(md5_hex);
use Path::Class;

use Slim::Utils::Cache;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;

*_imageInFolder = \&Plugins::MusicArtistInfo::Common::imageInFolder;

my $log   = logger('plugin.musicartistinfo');
my $prefs = preferences('plugin.musicartistinfo');
my $cache = Slim::Utils::Cache->new;
my ($defaultArtistImg, $fallbackArtistImg, $checkFallbackArtistImg, $imageCacheDir);

my %ignoreList = Slim::Utils::OSDetect::getOS->ignoredItems();
while (my ($k, $v) = each %ignoreList) {
	delete $ignoreList{$k} if $v != 1;
}

# some items which are exposed on shares on popular platforms
$ignoreList{'#recycle'} = 1;
$ignoreList{'#snapshot'} = 1;
$ignoreList{'@eaDir'} = 1;

sub init {
	my $serverprefs = preferences('server');
	$imageCacheDir = catdir($serverprefs->get('cachedir'), 'mai_embedded');
	mkdir $imageCacheDir unless -d $imageCacheDir;

	if (!main::SCANNER) {
		require Slim::Menu::AlbumInfo;
		require Slim::Menu::FolderInfo;
		require Slim::Menu::TrackInfo;
		require Slim::Web::ImageProxy;

		Slim::Menu::AlbumInfo->registerInfoProvider( moreartwork => (
			func => \&albumInfoHandler,
			after => 'moremusicinfo',
		) );

		Slim::Menu::FolderInfo->registerInfoProvider( moreartwork => (
			func => \&folderInfoHandler,
		) );

		Slim::Menu::TrackInfo->registerInfoProvider( moreartwork => (
			func => \&trackInfoHandler,
			after => 'moremusicinfo',
		) );

		Slim::Web::ImageProxy->registerHandler(
			match => qr/mai\/localartwork\/[a-f\d]+/,
			func  => \&artworkUrl,
		);

		$defaultArtistImg = Slim::Web::HTTP::getSkinManager->fixHttpPath($serverprefs->get('skin'), '/plugins/MusicArtistInfo/html/artist.png');

		_initDefaultArtistImg();
		$prefs->setChange(\&_initDefaultArtistImg, 'artistImageFolder');
	}
}

sub _initDefaultArtistImg {
	return unless $defaultArtistImg;

	if ( my $imageFolder = $prefs->get('artistImageFolder') ) {
		my $img = _imageInFolder($imageFolder, 'artist');
		my $placeholder = catfile($imageFolder, 'artist.png.missing');
		if ( !$img ) {
			File::Slurp::write_file($placeholder, { err_mode => 'carp' }, '' ) unless -f $placeholder;
		}
		else {
			unlink $placeholder if -f $placeholder;
		}
	}
}

sub albumInfoHandler {
	my ( $client, $url, $album ) = @_;

	# try to grab the first album track to find it's folder location
	return trackInfoHandler($client, undef, $album->tracks->first);
}

sub folderInfoHandler {
	my ( $client, $tags ) = @_;

	return unless $tags->{folder_id};

	return trackInfoHandler($client, undef, Slim::Schema->find('Track', $tags->{folder_id}), undef, $tags);
}

sub trackInfoHandler { if (!main::SCANNER) {
	my ( $client, $url, $track, $remoteMeta, $tags ) = @_;

	# only deal with local media
	$url = $track->url if !$url && $track;
	$url =~ s/^tmp:/file:/ if $url;
	return unless $url && $url =~ /^file:\/\//i;

	my $file = my $path = Slim::Utils::Misc::pathFromFileURL($url);

	if (! -d $path) {
		$path = dirname( $path );
	}

	my @images;

	# see whether a file has multiple artwork embedded
	if ($track->cover && $track->cover =~ /^\d+$/ && ! -d _) {
		# Enable artwork in Audio::Scan
		local $ENV{AUDIO_SCAN_NO_ARTWORK} = 0;

		my $s = Audio::Scan->scan_tags($file);
		my $tags = $s->{tags};

		my $pics;

		if ($tags->{ALLPICTURES} && ref $tags->{ALLPICTURES} && ref $tags->{ALLPICTURES} eq 'ARRAY') {
			$pics = [ sort {
				$a->{picture_type} <=> $b->{picture_type}
			} grep {
				# skip front picture
				$_->{picture_type} != 3
			} @{ $tags->{ALLPICTURES} } ];
		}
		elsif ($tags->{APIC} && ref $tags->{APIC} && ref $tags->{APIC} eq 'ARRAY' && ref $tags->{APIC}->[0]) {
			$pics = [
				map { {
					image_data => $_->[3],
					mime_type  => $_->[0],
				} } sort {
					$a->[1] <=> $b->[1]
				} @{ $tags->{APIC} }
			];

			# first is the front picture - skip it
			shift @$pics;
		}

		my $imgProxyCache = Slim::Web::ImageProxy::Cache->new();

		my $i = 0;;
		my $coverId = $track->coverid;
		foreach (@$pics) {
			my $file = catfile($imageCacheDir, "embedded-$coverId-$i.");
			my ($ext) = $_->{mime_type} =~ m|image/(.*)|;
			$ext =~ s/jpeg/jpg/;
			$file .= $ext;

			if (!-f $file) {
				File::Slurp::write_file($file, { binmode => ':raw' }, $_->{image_data});
			}

			push @images, $file;
			$i++;
		}
	}

	my $iterator = File::Next::files({
		file_filter => sub { /^[^.].*\.(?:jpe?g|png|gif)$/i },
		descend_filter => sub { !$ignoreList{$_} },
	}, $path);

	while ( defined (my $file = $iterator->()) ) {
		push @images, $file;
	}

	return unless scalar @images;

	my $items = [ map {
		my $imageUrl = Slim::Utils::Misc::fileURLFromPath($_);
		my $imageId  = proxiedUrl($imageUrl);

		{
			type  => 'text',
			name  => basename($_),
			image => $imageId,
			jive  => {
				showBigArtwork => 1,
				actions => {
					do => {
						cmd => [ 'artwork', $imageId ]
					},
				},
			}
		}
	} @images ];

	$items = [ sort { lc($a->{name}) cmp lc($b->{name}) } @$items ];

	return {
		name => cstring($client, 'PLUGIN_MUSICARTISTINFO_LOCAL_ARTWORK'),
		# we don't want slideshow mode on controllers, but web UI only
		type => ($client && $client->controllerUA || '') =~ /squeezeplay/i ? 'outline' : 'slideshow',
		items => $items,
	};
} }

sub proxiedUrl {
	my $url = shift;

	$url = Slim::Utils::Misc::fileURLFromPath($url);

	require Slim::Web::ImageProxy;

	my $imageId = 'mai/localartwork/' . md5_hex($url);
	$cache->set( $imageId, $url, 3600 );
	return "imageproxy/$imageId/image.png";
}

sub artworkUrl {
	my ($url, $spec) = @_;

	main::DEBUGLOG && $log->debug("Artwork for $url, $spec");

	my $fileUrl = $cache->get($url);

	main::DEBUGLOG && $log->debug("Artwork file path is '$fileUrl'");

	return $fileUrl;
}

sub defaultArtistPhoto {
	my ( $class ) = @_;

	$checkFallbackArtistImg ||= 0;

	# check whether the user has a generic 'artist.jpg' image in his folder
	if ( $checkFallbackArtistImg < time && (my $imageFolder = $prefs->get('artistImageFolder')) ) {
		$fallbackArtistImg = _imageInFolder($imageFolder, 'artist');
		# only check every minute...
		$checkFallbackArtistImg = time + 60;
	}

	return $fallbackArtistImg || $defaultArtistImg;
}

sub getArtistPhoto {
	my ( $class, $args ) = @_;

	my $artist    = $args->{artist} || 'no artist';
	my $artist_id = $args->{artist_id};

	my $cachekey = 'mai_artist_photo_' . Slim::Utils::Text::ignoreCaseArticles($artist, 1);
	if ( !$args->{force} && (my $local = $cache->get($cachekey)) ) {
		if (-f $local) {
			return $args->{rawUrl} ? $local : proxiedUrl($local);
		}
	}

	my $img;
	my $imageFolder = $prefs->get('artistImageFolder');

	my $candidates = Plugins::MusicArtistInfo::Common::getLocalnameVariants($artist);

	if ($imageFolder) {
		$img = _imageInFolder($imageFolder, @$candidates);

		# don't look up generic artists like "no artist" or "various artists" etc.
		if (!$img) {
			my $vaString = Slim::Music::Info::variousArtistString();
			my $noArtistString = Slim::Utils::Strings::string('NO_ARTIST');

			if ( $artist =~ /^(?:no artist|Various Artist|Various$|va$|\Q$vaString\E|\Q$noArtistString\E)/i ) {
				$img = $class->defaultArtistPhoto();
			}
		}
	}

	# when checking music folders, check for artist.jpg etc., too
	push @$candidates, 'artist', 'composer';

	# check album folders for artist artwork, too
	if (!$img && $artist_id && $artist_id ne $artist) {
		my $sql = qq(
			SELECT url
			FROM tracks
			JOIN contributor_track ON contributor_track.track = tracks.id
			-- only ALBUMARTIST and ARTIST roles
			WHERE contributor_track.contributor = ? AND role IN (5, 1) AND tracks.url LIKE 'file://%'
			GROUP BY album
		);

		my $sth = Slim::Schema->dbh->prepare_cached($sql);
		$sth->execute($artist_id);

		my %seen;
		while (my $track = $sth->fetchrow_hashref) {
			my $path = Slim::Utils::Misc::pathFromFileURL($track->{url});
			$path = dirname($path) if !-d $path;

			my $parent = Path::Class::dir($path)->parent;

			# check parent folder, assuming many have a music/artist/album hierarchy
			if ( $parent && !$seen{$parent} ) {
				$img = _imageInFolder($parent->stringify, @$candidates);
				last if $img;

				$seen{$parent}++;
			}

			# look for pictures called $artist or literal artist.jpg in the album folder
			$img = _imageInFolder($path, @$candidates);
			last if $img;
		}

		$sth->finish;
	}

	if ($img) {
		main::INFOLOG && $log->is_info && $log->info("Found local artwork $img");
		$img = Slim::Utils::Unicode::utf8encode($img);
		$cache->set($cachekey, $img);
	}

	return ($args->{rawUrl} || !$img) ? $img : proxiedUrl($img);
}

sub purgeCacheFolder {
	my $iterator = File::Next::files($imageCacheDir);

	my $dbh = Slim::Schema->dbh;
	my $sth = $dbh->prepare_cached("SELECT id FROM tracks WHERE coverid = ? LIMIT 1");

	while ( defined (my $file = $iterator->()) ) {
		if ($file =~ m|/embedded-([a-f0-9]{8})-\d+|) {
			$sth->execute($1);
			my ($trackId) = $sth->fetchrow_array;
			next() if $trackId;
		}

		unlink $file;
	}

	$sth->finish;
}

1;