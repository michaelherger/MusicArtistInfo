package Plugins::MusicArtistInfo::AllMusic::Sync;

use strict;

use Slim::Networking::SimpleSyncHTTP;
use Slim::Utils::Cache;

use Plugins::MusicArtistInfo::AllMusic::Common qw(BASE_URL ALBUMSEARCH_URL);
use Plugins::MusicArtistInfo::Common;

my $cache = Slim::Utils::Cache->new();

my $http = Slim::Networking::SimpleSyncHTTP->new({
	expires => 86399,
	cache => 1
});

sub searchAlbums {
	my ($class, $args) = @_;

	my $url = sprintf(
		ALBUMSEARCH_URL,
		URI::Escape::uri_escape_utf8($args->{artist}),
		URI::Escape::uri_escape_utf8($args->{album})
	);

	my $result = $http->get($url);
	my $bodyRef = $result->contentRef;

	my $albums = [];

	while ($$bodyRef =~ m{<li class="album">(.*?)<\/li}gs) {
		my $snippet = $1;
		my $album = {};

		if ($snippet =~ m{class="title">.*?>\s*(.*?)\s*</}gs) {
			$album->{album} = $1;
		}
		if ($snippet =~ m{class="artist">.*?>\s*(.*?)\s*</}gs) {
			$album->{artist} = $1;
		}
		if ($snippet =~ m{"year">\s*?(\d+)}gs) {
			$album->{year} = $1;
		}
		if ($snippet =~ m{class="genres">\s*(.*?)\s*</div}gs) {
			$album->{genres} = $1;
		}

		push @$albums, $album if keys %$album;
	}

	return $albums;
}

sub getAlbumInfo {
	my ($class, $args) = @_;

	my $cacheKey = 'mai_albuminfo_' . Slim::Utils::Text::ignoreCaseArticles($args->{artist}, 1) . '|' . Slim::Utils::Text::ignoreCaseArticles($args->{album}, 1);

	if (my $cached = $cache->get($cacheKey)) {
		return $cached;
	}

	my $albums = $class->searchAlbums($args);
	my ($album) = grep {
		Plugins::MusicArtistInfo::Common->matchAlbum($args, $_, 'strict')
		|| Plugins::MusicArtistInfo::Common->matchAlbum($args, $_);
	} @$albums;

	if ($album) {
		$cache->set($cacheKey, $album, time() + 90 * 86400 + rand(7) * 86400);
	}

	return $album;
}

1;