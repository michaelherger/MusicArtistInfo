package Plugins::MusicArtistInfo::API;

use strict;
use URI::Escape qw(uri_escape_utf8);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use constant ARTISTIMAGESEARCH_URL => 'https://api.lms-community.org/music/artist/%s/picture';
# use constant ARTISTIMAGESEARCH_URL => 'http://localhost:8787/artist/%s/picture';

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.musicartistinfo');
my $prefs = preferences('plugin.musicartistinfo');
my $serverPrefs = preferences('server');

my $xMAICfgString = _initXMAICfgString();

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
	my ( $class, $client, $cb, $args ) = @_;

	my $query = '?mbid=' . $args->{mbid} if $args->{mbid};
	my $url = sprintf(ARTISTIMAGESEARCH_URL, uri_escape_utf8($args->{artist})) . $query;
	my $cacheKey = "mai_artist_artwork_$url";

	if (my $cached = $cache->get($cacheKey)) {
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

				$cache->set($cacheKey, $url, '60d');
			}

			main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump($photo));

			$cb->($photo);
		},{
			cache => 1,
			headers => {
				'x-mai-cfg' => $xMAICfgString,
			},
			# ignoreError => [404],
		}
	);
}

sub _initXMAICfgString {
	return $xMAICfgString = sprintf('sc:%s,ba:%s,la:%s,ma:%s,ac:%s,pc:%s,ph:%s',
		main::SCANNER ? 1 : 0,
		$prefs->get('browseArtistPictures') ? 1 : 0,
		$prefs->get('lookupArtistPictures') ? 1 : 0,
		$prefs->get('lookupAlbumArtistPicturesOnly') ? 1 : 0,
		$prefs->get('artistImageFolder') ? 1 : 0,
		$serverPrefs->get('precacheArtwork') ? 1 : 0,
		$prefs->get('saveMissingArtistPicturePlaceholder') ? 1 : 0,
	);
}

1;