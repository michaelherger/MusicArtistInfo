package Plugins::MusicArtistInfo::API;

use strict;
use Digest::SHA1 qw(sha1_base64);
use URI::Escape qw(uri_escape_utf8);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use constant BASE_URL => 'https://api.lms-community.org/music';
# use constant BASE_URL => 'http://127.0.0.1:8787/music';
use constant ARTISTIMAGESEARCH_URL => BASE_URL . '/artist/%s/picture';
use constant ALBUMREVIEW_URL => BASE_URL . '/album/%s/%s/review';
use constant ALBUMGENRES_URL => BASE_URL . '/album/%s/%s/genres';
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

	_call(
		$url,
		sub {
			my ($result) = @_;

			my $photo;

			if ($result && ref $result && (my $url = $result->{picture})) {
				$photo = {
					url => $url,
				};
			}

			$cache->set($cacheKey, $photo->{url}, '1y') if $photo->{url};

			main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump($photo));

			$cb->($photo);
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

	_call(
		$url,
		sub {
			my ($result) = @_;

			main::INFOLOG && $log->is_info && $log->info("found biography: " . Data::Dump::dump($result));

			$cb->($result);
		}
	);
}

sub getAlbumReviewId {
	my ( $class, $cb, $args ) = @_;

	my $url = _prepareAlbumUrl(ALBUMREVIEW_URL, $args);

	_call(
		$url,
		sub {
			my ($result) = @_;

			main::INFOLOG && $log->is_info && $log->info("found album review: " . Data::Dump::dump($result));

			$cb->($result);
		}
	);
}

sub getAlbumGenres {
	my ( $class, $cb, $args ) = @_;

	my $url = _prepareAlbumUrl(ALBUMGENRES_URL, $args);

	_call(
		$url,
		sub {
			my ($result) = @_;

			main::INFOLOG && $log->is_info && $log->info("found album genres: " . Data::Dump::dump($result));

			$cb->($result);
		}
	);
}

sub _call {
	my ($url, $cb, $args) = @_;

	$args ||= {};
	$args->{cache} //= 1;
	$args->{expires} //= '30d';
	$args->{headers} ||= {};
	$args->{headers}->{'x-mai-cfg'} ||= _initXMAICfgString();

	Plugins::MusicArtistInfo::Common->call($url, $cb, $args);
}

sub _prepareAlbumUrl {
	my ($url, $args) = @_;

	my @queryParams;
	push @queryParams, 'mbid=' . $args->{mbid} if $args->{mbid};
	push @queryParams, 'lang=' . $args->{lang} if $args->{lang};

	my ($service, $extid) = split /:album:/, $args->{extid} || '';
	push @queryParams, $service . '=' . $extid if $service && $extid;

	my $query = @queryParams ? '?' . join('&', @queryParams) : '';

	return sprintf($url, uri_escape_utf8($args->{album}), uri_escape_utf8($args->{artist})) . $query;
}

sub _initXMAICfgString {
	$version ||= (main::SCANNER && Slim::Utils::PluginManager->dataForPlugin('Plugins::MusicArtistInfo::Importer')->{version})
	          || (!main::SCANNER && $Plugins::MusicArtistInfo::Plugin::VERSION) || 'unk';

	my $serverId = 'undef';

	if (!$xMAICfgString && Slim::Utils::PluginManager->isEnabled('Slim::Plugin::Analytics::Plugin')) {
		$serverId = sha1_base64(preferences('server')->get('server_uuid'));
		# replace / with +, as / would be interpreted as a path part
		$serverId =~ s/\//+/g;
	}

	return $xMAICfgString ||= sprintf('v:%s,sc:%s,ba:%s,la:%s,ma:%s,ac:%s,pc:%s,si:%s',
		$version,
		main::SCANNER ? 1 : 0,
		$prefs->get('browseArtistPictures') ? 1 : 0,
		$prefs->get('lookupArtistPictures') ? 1 : 0,
		$prefs->get('lookupAlbumArtistPicturesOnly') ? 1 : 0,
		$prefs->get('artistImageFolder') ? 1 : 0,
		$serverPrefs->get('precacheArtwork') ? 1 : 0,
		$serverId,
	);
}

1;