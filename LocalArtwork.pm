package Plugins::MusicArtistInfo::LocalArtwork;

use strict;
use File::Basename qw(dirname);
use File::Spec::Functions qw(catdir);
use Digest::MD5 qw(md5_hex);

use Slim::Utils::Cache;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;

my $log   = logger('plugin.musicartistinfo');
my $prefs = preferences('plugin.musicartistinfo');
my $cache = Slim::Utils::Cache->new;

sub init { if (!main::SCANNER) {
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
} }

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
	
	opendir(DIR, $path) || return;
	my @images = grep { $_ !~ /^\._/ } grep /\.(?:jpe?g|png|gif)$/i, readdir(DIR);
	closedir(DIR);

	return unless scalar @images;
	
	my $items = [ map {
		my $imageUrl = Slim::Utils::Misc::fileURLFromPath( catdir($path, $_) );
		my $imageId  = _proxiedUrl($imageUrl);

		{
			type  => 'text',
			name  => $_,
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
	
	return {
		name => cstring($client, 'PLUGIN_MUSICARTISTINFO_LOCAL_ARTWORK'),
		# we don't want slideshow mode on controllers, but web UI only
		type => ($client && $client->controllerUA || '') =~ /squeezeplay/i ? 'outline' : 'slideshow',
		items => $items,
	};	
} }

sub _proxiedUrl {
	my $url = shift;

	require Slim::Web::ImageProxy;

	my $imageId = 'mai/localartwork/' . md5_hex($url);
	$cache->set( $imageId, $url, 3600 );
	return Slim::Web::ImageProxy::proxiedImage($imageId, 'force');
}

sub artworkUrl {
	my ($url, $spec) = @_;
	
	main::DEBUGLOG && $log->debug("Artwork for $url, $spec");
	
	my $fileUrl = $cache->get($url);

	main::DEBUGLOG && $log->debug("Artwork file path is '$fileUrl'");

	return $fileUrl;
}

sub getArtistPhoto {
	my ( $class, $args ) = @_;
	
	my $artist    = $args->{artist};
	my $artist_id = $args->{artist_id};
	
	my $cachekey = 'mai_artist_photo_' . Slim::Utils::Text::ignoreCaseArticles($artist, 1);
	if ( !$args->{force} && (my $local = $cache->get($cachekey)) ) {
		return $args->{rawUrl} ? $local : _proxiedUrl($local);
	}
	
	my $img;
	my $imageFolder = $prefs->get('artistImageFolder');
	
	if ($imageFolder) {
		my $artist2 = Slim::Utils::Text::ignorePunct($artist);
		$img = _imageInFolder($imageFolder, "(?:\Q$artist2\E|\Q$artist\E)");
	}
	
	if (!$img && $artist_id && $artist_id ne $artist) {
		my $tracks = Slim::Schema->search("Track", {
			primary_artist => $artist_id,
		},{
			group_by => 'me.album',
		});
		
		while (my $track = $tracks->next) {
			my $path = Slim::Utils::Misc::pathFromFileURL($track->url);
			$path = dirname($path) if !-d $path;
			
			$img = _imageInFolder($path, "(?:\Q$artist\E|artist)");
			last if $img;
		}
	}

	if ($img) {
		main::DEBUGLOG && $log->debug("Found local artwork $img");
		$img = Slim::Utils::Misc::fileURLFromPath($img);
		$cache->set($cachekey, $img);
	}
	
	return ($args->{rawUrl} || !$img) ? $img : _proxiedUrl($img);
}

sub _imageInFolder {
	my ($folder, $name) = @_;

	main::DEBUGLOG && $log->debug("Trying to find artwork in $folder");
	
	my $img;
		
	if ( opendir(DIR, $folder) ) {
		while (readdir(DIR)) {
			if (/$name\.(?:jpe?g|png|gif)$/i) {
				$img = catdir($folder, $_);
				last;
			}
		}
		closedir(DIR);
	}
	else {
		$log->error("Unable to open dir '$folder'");
	}
	
	return $img;
}

1;