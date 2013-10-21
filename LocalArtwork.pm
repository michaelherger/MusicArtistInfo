package Plugins::MusicArtistInfo::LocalArtwork;

use strict;
use File::Basename qw(dirname);
use File::Spec::Functions qw(catdir);
use Digest::MD5 qw(md5_hex);

use Slim::Menu::AlbumInfo;
use Slim::Menu::FolderInfo;
use Slim::Menu::TrackInfo;
use Slim::Utils::Cache;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Web::ImageProxy qw(proxiedImage);

my $log = logger('plugin.musicartistinfo');

sub init {
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

sub trackInfoHandler {
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
	
	my $cache = Slim::Utils::Cache->new;

	my $items = [ map {
		my $imageUrl = Slim::Utils::Misc::fileURLFromPath( catdir($path, $_) );
		my $imageId = 'mai/localartwork/' . md5_hex($imageUrl);

		$cache->set( $imageId, $imageUrl, 3600 );
		
		$imageId = proxiedImage($imageId, 'force');
		
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
}

sub artworkUrl {
	my ($url, $spec) = @_;
	
	main::DEBUGLOG && $log->debug("Artwork for $url, $spec");
	
	my $fileUrl = Slim::Utils::Cache->new->get($url);

	main::DEBUGLOG && $log->debug("Artwork file path is '$fileUrl'");

	return $fileUrl;
}


1;