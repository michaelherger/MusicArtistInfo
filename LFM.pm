package Plugins::MusicArtistInfo::LFM;

use strict;
use URI::Escape qw(uri_escape_utf8);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Text;
use Slim::Utils::Strings qw(string cstring);

use Plugins::MusicArtistInfo::Common;

use constant BASE_API_URL => 'http://ws.audioscrobbler.com/2.0/';
use constant BASE_URL     => 'https://www.last.fm/music/';
use constant ARTISTIMAGESEARCH_URL => BASE_URL . '%s/+images';

my $cache = Slim::Utils::Cache->new;
my $log = logger('plugin.musicartistinfo');

sub getLargestPhotoFromList {
	my ( $class, $photos, $minSize ) = @_;

	$photos = [ $photos ] if $photos && ref $photos eq 'HASH';

	return unless $photos && ref $photos eq 'ARRAY';

	my %photos = map {
		$_->{size} => $_->{'#text'}
	} grep {
		$_->{size} && $_->{'#text'} && $_->{'#text'} !~ m{/arQ/};
	} @$photos;

	my ($url, $size);
	foreach ( qw(mega extralarge large medium small) ) {
		$size = $_;
		if ($url = $photos{$size}) {
			last;
		};

		last if $minSize && $size eq $minSize;
	}

	if (wantarray) {
		$url =~ m{/(34|64|126|174|252|500|\d+x\d+)s?/}i;
		return $url, ($1 || $size);
	}

	return $url;
}

sub getBiography {
	my ( $class, $client, $cb, $args ) = @_;

	_call({
		method => 'artist.getInfo',
		artist => $args->{artist},
		lang   => $args->{lang} || 'en',
		autocorrect => 1,
	}, sub {
		my $artistInfo = shift;

		if ( $artistInfo && ref $artistInfo && $artistInfo->{artist} && $artistInfo->{artist}->{bio} && (my $content = $artistInfo->{artist}->{bio}->{content})) {
			$cb->({
				# author => 'Last.fm',
				bio => $content
			});
		}
		else {
			$cb->({ error => cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND') })
		}
	});
}

sub getArtistPhotos {
	my ( $class, $client, $cb, $args ) = @_;
	$class->_getArtistPhotos($client, sub {
		my ($result) = @_;

		if (!$result && uc($args->{artist}) ne Slim::Utils::Text::ignoreCaseArticles($args->{artist}, 1) ) {
			$args->{simplify} = 1;
			$class->_getArtistPhotos($client, sub {
				$cb->(@_);
			}, $args);
		}
		else {
			$cb->(@_);
		}
	}, $args);
}

sub _getArtistPhotos {
	my ( $class, $client, $cb, $args ) = @_;

	my $artist = $args->{artist} || $args->{name};

	if (!$artist) {
		$cb->();
		return;
	}

	my $simplifiedArtist = Slim::Utils::Text::ignoreCaseArticles($artist, 1);
	my $key = "lfm_artist_photos_" . $simplifiedArtist;
	$cache ||= Slim::Utils::Cache->new;
	if ( my $cached = $cache->get($key) ) {
		$cb->($cached);
		return;
	}

	Plugins::MusicArtistInfo::Common->call(
		sprintf(ARTISTIMAGESEARCH_URL, uri_escape_utf8($args->{simplify} ? $simplifiedArtist : $artist)),
		sub {
			my ($results) = @_;

			my $result;

			if ($results && !ref $results) {
				my $photos = [];

				while ($results =~ /class="image-list-item"(.*?)<\//isg) {
					my $image = $1;
					if ($image =~ /src.*?=.*?"(http.*?)"/is) {
						my $url = $1;
						$url =~ s/avatar170s\///;
						$url .= '.jpg' if $url !~ /\.(png|jp.?g)/i;

						push @$photos, {
							author => 'Last.fm',
							url    => $url,
						};
					}
				}

				if (scalar @$photos) {
					$result = {
						photos => $photos
					};

					# we keep an aggressive cache of artist pictures - they don't change often, but are often used
					$cache->set($key, $result, 86400 * 30);
				}
				else {
					$cache->set($key, '', 3600 * 5);
				}

			}

			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($result));

			$cb->($result);
		},{
			cache => 1,
			expires => 86400,	# force caching
		}
	);
}

# get a single artist picture - wrapper around getArtistPhotos
sub getArtistPhoto {
	my ( $class, $client, $cb, $args ) = @_;

	$class->getArtistPhotos($client, sub {
		my $items = shift || {};

		my $photo;
		if ($items->{error}) {
			$photo = $items;
		}
		elsif ($items->{photos} && scalar @{$items->{photos}}) {
			$photo = $items->{photos}->[0];
		}

		if (!$photo && $main::SERVER) {
			$photo = {
				error => cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND')
			};
		}

		$cb->($photo);
	},
	$args );
}

sub getAlbumCover {
	my ( $class, $client, $cb, $args ) = @_;

	my $key = "mai_lfm_albumcover_" . Slim::Utils::Text::ignoreCaseArticles($args->{artist} . $args->{album}, 1);

	if (my $cached = $cache->get($key)) {
		$cb->($cached);
		return;
	}

	$class->getAlbumCovers($client, sub {
		my $covers = shift;

		my $cover = {};

		# getAlbumCovers() would only return a single item
		if ($covers && ref $covers && $covers->{images} && ref $covers->{images} eq 'ARRAY') {
			$cover = $covers->{images}->[0];
		}

		$cache->set($key, $cover, 86400);
		$cb->($cover);
	}, $args);
}

# TODO - needs scraping, too?
sub getAlbumCovers {
	my ( $class, $client, $cb, $args ) = @_;

	$class->getAlbum(sub {
		my $albumInfo = shift;
		my $result = {};

		if ( $albumInfo && ref $albumInfo && $albumInfo->{album} && (my $image = $albumInfo->{album}->{image}) ) {
			my ($url, $size) = $class->getLargestPhotoFromList($image, 'extralarge');
			if ( $url && $size ) {
				$result->{images} = [{
					author => 'Last.fm',
					url    => $url,
					width  => $size,
				}];
			}
		}

		if ( !$result->{images} && !main::SCANNER ) {
			$result->{error} ||= cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND');
		}

		$cb->($result);
	}, $args);
}

sub getAlbum {
	my ( $class, $cb, $args ) = @_;

	if (!$args->{artist} || !$args->{album}) {
		$cb->();
		return;
	}

	_call({
		method => 'album.getinfo',
		artist => $args->{artist},
		album  => $args->{album},
		autocorrect => 1,
	}, sub {
		$cb->(shift);
	});
}

sub _call {
	my ( $args, $cb ) = @_;

	Plugins::MusicArtistInfo::Common->call(
		BASE_API_URL . '?' . join( '&', Plugins::MusicArtistInfo::Common->getQueryString($args), Plugins::MusicArtistInfo::Common->getHeaders('lfm'), 'format=json' ),
		$cb,
		{
			cache => 1,
			expires => 86400,	# force caching - discogs doesn't set the appropriate headers
		}
	);
}

1;