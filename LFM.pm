package Plugins::MusicArtistInfo::LFM;

use strict;

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Text;
use Slim::Utils::Strings qw(string cstring);

use Plugins::MusicArtistInfo::Common;

use constant BASE_URL => 'http://ws.audioscrobbler.com/2.0/';

my $cache = Slim::Utils::Cache->new;
my $log = logger('plugin.musicartistinfo');
my $aid;

sub init {
	shift->aid(shift->_pluginDataFor('id2'));
}

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
	foreach $size ( qw(mega extralarge large medium small) ) {
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

sub getArtistPhotos {
	my ( $class, $client, $cb, $args ) = @_;

	my $artist = $args->{artist} || $args->{name};
	
	if (!$artist) {
		$cb->();
		return;
	}

	my $key = "lfm_artist_photos_" . Slim::Utils::Text::ignoreCaseArticles($artist, 1);
	$cache ||= Slim::Utils::Cache->new;	
	if ( my $cached = $cache->get($key) ) {
		$cb->($cached);
		return;
	}
	
	_call({
		method => 'artist.getInfo',
		artist => $artist,
		autocorrect => 1,
	}, sub {
		my $artistInfo = shift;
		my $result = {};
		
		if ( $artistInfo && $artistInfo->{artist} && (my $images = $artistInfo->{artist}->{image}) ) {
			if ( my ($url, $size) = $class->getLargestPhotoFromList($images) ) {

				$result->{photos} = [ {
					author => 'Last.fm',
					url    => $url,
					width  => $size * 1 || undef
				}];

				# we keep an aggressive cache of artist pictures - they don't change often, but are often used
				$cache->set($key, $result, 86400 * 30);
			}
			else {
				$cache->set($key, '', 3600 * 5);
			}
		}

		if ( !$result->{photos} && $main::SERVER ) {
			$result->{error} ||= cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND');
		}
		
		$cb->($result);
	});
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
			foreach (@{$items->{photos}}) {
				if ( my $url = $_->{url} ) {
					$photo = $_;
					last;
				}
			}
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
		if ($covers && $covers->{images} && ref $covers->{images} eq 'ARRAY') {
			$cover = $covers->{images}->[0];
		}
		
		$cache->set($key, $cover, 86400);
		$cb->($cover);
	}, $args);	
}

sub getAlbumCovers {
	my ( $class, $client, $cb, $args ) = @_;
	
	$class->getAlbum(sub {
		my $albumInfo = shift;
		my $result = {};
		
		if ( $albumInfo && $albumInfo->{album} && (my $image = $albumInfo->{album}->{image}) ) {
			if ( my ($url, $size) = $class->getLargestPhotoFromList($image, 'extralarge') ) {
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
		BASE_URL . '?' . join( '&', @{Plugins::MusicArtistInfo::Common->getQueryString($args)}, 'api_key=' . aid(), 'format=json' ), 
		$cb,
		{ cache => 1 }
	);
}

sub aid {
	if ( $_[1] ) {
		$aid = $_[1];
		$aid =~ s/-//g;
		$cache->set('lfm_aid', $aid, 'never');
	}
	
	$aid ||= $cache->get('lfm_aid');

	return $aid; 
}

1;