package Plugins::MusicArtistInfo::LocalArtwork;

use strict;
use File::Basename qw(dirname);
use File::Spec::Functions qw(catdir);
use Digest::MD5 qw(md5_hex);

use Slim::Menu::AlbumInfo;
use Slim::Menu::TrackInfo;
use Slim::Utils::Cache;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Web::ImageProxy qw(proxiedImage);

my $log = logger('plugin.musicartistinfo');

sub init {
	Slim::Menu::TrackInfo->registerInfoProvider( moremusicinfo => (
		func => \&trackInfoHandler,
	) );

	Slim::Menu::AlbumInfo->registerInfoProvider( moremusicinfo => (
		func => \&albumInfoHandler,
	) );

	Slim::Web::ImageProxy->registerHandler(
		match => qr/mai\|[a-f\d]+/,
		func  => \&artworkUrl,
	);
}

sub albumInfoHandler {
	my ( $client, $url, $album ) = @_;
	
	# try to grab the first album track to find it's folder location
	my $track = $album->tracks->first;
	
	return trackInfoHandler($client, $track->url) if $track;
}

sub trackInfoHandler {
	my ( $client, $url ) = @_;

	# only deal with local media
	return unless $url && $url =~ /^file:\/\//i;
	
	my $path = dirname( Slim::Utils::Misc::pathFromFileURL($url) );
	
	opendir(DIR, $path) || return;
	my @images = grep /\.(?:jpe?g|png|gif)$/i, readdir(DIR);
	closedir(DIR);

	return unless scalar @images;
	
	my $cache = Slim::Utils::Cache->new;

	my $items = [ map {
		my $imageUrl = Slim::Utils::Misc::fileURLFromPath( catdir($path, $_) );
		my $imageId = 'mai|' . md5_hex($imageUrl);

		$cache->set( $imageId, $imageUrl, 3600 );
		
		$imageId = proxiedImage($imageId, 'force');
		
		{
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
		type => 'outline',
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