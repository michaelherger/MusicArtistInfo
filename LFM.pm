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

sub getArtistPhotos {
	my ( $class, $client, $cb, $args ) = @_;

	my $artist = $args->{artist};
	
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
		# XXX - artist.getimages has been deprecated by October 2013. getInfo will only return one image :-(
#		method => 'artist.getimages',
		method => 'artist.getInfo',
		artist => $artist,
		autocorrect => 1,
	}, sub {
		my $artistInfo = shift;
		my $result = {};
		
#		if ( $artistInfo && $artistInfo->{images} && (my $images = $artistInfo->{images}->{image}) ) {
		if ( $artistInfo && $artistInfo->{artist} && (my $images = $artistInfo->{artist}->{image}) ) {
			$images = [ $images ] if ref $images eq 'HASH';
			
			if ( ref $images eq 'ARRAY' ) {
#				my @images;
#				foreach my $image (@$images) {
#					my $img;
#					
#					if ($image->{sizes} && $image->{sizes}->{size}) {
#						my $max = 0;
#						
#						foreach ( @{$image->{sizes}->{size}} ) {
#							next if $_->{width} < 250;
#							next if $_->{width} < $max;
#							
#							$max = $_->{width};
#							
#							$img = $_;
#						}
#					}
#					
#					next unless $img;
#					
#					push @images, {
#						author => $image->{owner}->{name} . ' (Last.fm)',
#						url    => $img->{'#text'},
#						height => $img->{height},
#						width  => $img->{width},
#					};
#				}

				my $url = $images->[-1]->{'#text'};
				my ($size) = $url =~ m{/(34|64|126|174|252|500|\d+x\d+)s?/}i;

				my @images = ({
					author => 'Last.fm',
					url    => $url,
					width  => $size * 1 || undef
				});

				if (@images) {
					$result->{photos} = \@images;

					# we keep an aggressive cache of artist pictures - they don't change often, but are often used
					$cache->set($key, $result, 86400 * 30);
				}
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

		# XXX - can we be smarter than return the first image?		
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
			$image = [ $image ] if ref $image eq 'HASH';

			if ( ref $image eq 'ARRAY' ) {
				$result->{images} = [ reverse grep {
					$_
				} map {
					my ($size) = $_->{'#text'} =~ m{/(34|64|126|174|252|500|\d+x\d+)s?/}i;
					
					# ignore sizes smaller than 300px
					{
						author => 'Last.fm',
						url    => $_->{'#text'},
						width  => $size || $_->{size},
					} if $_->{'#text'} && (!$size || $size*1 >= 300);
				} @{$image} ];
				
				delete $result->{images} unless scalar @{$result->{images}};
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