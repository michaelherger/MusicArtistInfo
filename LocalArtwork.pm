package Plugins::MusicArtistInfo::LocalArtwork;

use strict;
use File::Basename qw(dirname basename);
use File::Next;
use File::Spec::Functions qw(catdir);
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
my ($defaultArtistImg, $fallbackArtistImg, $checkFallbackArtistImg);

sub init {
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

		$defaultArtistImg = Slim::Web::HTTP::getSkinManager->fixHttpPath('', '/html/images/artists.png');

		_initDefaultArtistImg();
		$prefs->setChange(\&_initDefaultArtistImg, 'artistImageFolder');
	}
}

sub _initDefaultArtistImg {
	return unless $defaultArtistImg;

	if ( my $imageFolder = $prefs->get('artistImageFolder') ) {
		my $img = catdir($imageFolder, 'artist.png');
		if ( !-f $img ) {
			require File::Copy;
			File::Copy::copy($defaultArtistImg, $img);
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
	return unless $url && $url =~ /^file:\/\//i;

	my $path = Slim::Utils::Misc::pathFromFileURL($url);

	if (! -d $path) {
		$path = dirname( $path );
	}

	my $iterator = File::Next::files({
		file_filter => sub { /\.(?:jpe?g|png|gif)$/i }
	}, $path);

	my @images;
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
			WHERE contributor_track.contributor = ?
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

1;