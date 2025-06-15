package Plugins::MusicArtistInfo::API;

use strict;
use URI::Escape qw(uri_escape_utf8);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use constant BASE_URL => 'https://api.lms-community.org/music';
# use constant BASE_URL => 'http://127.0.0.1:8787/music';
use constant ARTISTIMAGESEARCH_URL => BASE_URL . '/artist/%s/picture';
use constant ALBUMREVIEW_URL => BASE_URL . '/album/%s/%s/review';
use constant BIOGRAPHY_URL => BASE_URL . '/artist/%s/biography';

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.musicartistinfo');
my $prefs = preferences('plugin.musicartistinfo');
my $serverPrefs = preferences('server');

my $xMAICfgString;
my $version;

if (!main::SCANNER) {
	$prefs->setChange(\&_initXMAICfgString,
		'browseArtistPictures',
		'lookupArtistPictures',
		'lookupAlbumArtistPicturesOnly',
		'artistImageFolder',
		'saveMissingArtistPicturePlaceholder'
	);

	$serverPrefs->setChange(\&_initXMAICfgString,
		'precacheArtwork',
	);
}

sub getArtistPhoto {
	my ( $class, $cb, $args ) = @_;

	my $query = '?mbid=' . $args->{mbid} if $args->{mbid};
	my $url = sprintf(ARTISTIMAGESEARCH_URL, uri_escape_utf8($args->{artist})) . $query;
	my $cacheKey = "mai_artist_artwork_$url";

	my $cached = $cache->get($cacheKey);
	if (defined $cached) {
		main::INFOLOG && $log->is_info && $log->info("Using cached artist picture: $cached");
		return $cb->({ url => $cached });
	}

	Plugins::MusicArtistInfo::Common->call(
		$url,
		sub {
			my ($result) = @_;

			my $photo;

			if ($result && ref $result && (my $url = $result->{picture})) {
				$photo = {
					url => $url,
				};
			}

			$cache->set($cacheKey, $photo->{url}, $photo->{url} ? '60d' : '10d');

			main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump($photo));

			$cb->($photo);
		},{
			cache => 1,
			headers => {
				'x-mai-cfg' => _initXMAICfgString(),
			},
			# ignoreError => [404],
		}
	);
}

sub getArtistBioId {
	my ( $class, $cb, $args ) = @_;

	my @queryParams;
	push @queryParams, 'mbid=' . $args->{mbid} if $args->{mbid};
	push @queryParams, 'lang=' . $args->{lang} if $args->{lang};
	my $query = @queryParams ? '?' . join('&', @queryParams) : '';

	my $url = sprintf(BIOGRAPHY_URL, uri_escape_utf8($args->{artist})) . $query;
	my $cacheKey = "mai_biography_$url";

	my $cached = $cache->get($cacheKey);
	if (defined $cached) {
		main::INFOLOG && $log->is_info && $log->info("Using cached album review: " . Data::Dump::dump($cached));
		return $cb->($cached);
	}

	Plugins::MusicArtistInfo::Common->call(
		$url,
		sub {
			my ($result) = @_;

			$cache->set($cacheKey, $result, ($result && $result->{wikidata}) ? '1y' : '30d');

			main::INFOLOG && $log->is_info && $log->info("found biography: " . Data::Dump::dump($result));

			$cb->($result);
		},{
			cache => 1,
			headers => {
				'x-mai-cfg' => _initXMAICfgString(),
			},
		}
	);
}

sub getAlbumReviewId {
	my ( $class, $cb, $args ) = @_;

	my @queryParams;
	push @queryParams, 'mbid=' . $args->{mbid} if $args->{mbid};
	push @queryParams, 'lang=' . $args->{lang} if $args->{lang};
	my $query = @queryParams ? '?' . join('&', @queryParams) : '';
	my $url = sprintf(ALBUMREVIEW_URL, uri_escape_utf8($args->{album}), uri_escape_utf8($args->{artist})) . $query;
	my $cacheKey = "mai_album_review_$url";

	my $cached = $cache->get($cacheKey);
	if (defined $cached) {
		main::INFOLOG && $log->is_info && $log->info("Using cached album review: " . Data::Dump::dump($cached));
		return $cb->($cached);
	}

	Plugins::MusicArtistInfo::Common->call(
		$url,
		sub {
			my ($result) = @_;

			$cache->set($cacheKey, $result, ($result && $result->{wikidata}) ? '1y' : '30d');

			main::INFOLOG && $log->is_info && $log->info("found album review: " . Data::Dump::dump($result));

			$cb->($result);
		},{
			cache => 1,
			headers => {
				'x-mai-cfg' => _initXMAICfgString(),
			},
		}
	);
}

sub _initXMAICfgString {
	$version ||= (main::SCANNER && Slim::Utils::PluginManager->dataForPlugin('Plugins::MusicArtistInfo::Importer')->{version})
	          || (!main::SCANNER && $Plugins::MusicArtistInfo::Plugin::VERSION) || 'unk';

	return $xMAICfgString ||= sprintf('v:%s,sc:%s,ba:%s,la:%s,ma:%s,ac:%s,pc:%s',
		$version,
		main::SCANNER ? 1 : 0,
		$prefs->get('browseArtistPictures') ? 1 : 0,
		$prefs->get('lookupArtistPictures') ? 1 : 0,
		$prefs->get('lookupAlbumArtistPicturesOnly') ? 1 : 0,
		$prefs->get('artistImageFolder') ? 1 : 0,
		$serverPrefs->get('precacheArtwork') ? 1 : 0,
	);
}

1;