package Plugins::MusicArtistInfo::Discogs;

use strict;

use Slim::Utils::Cache;
use Slim::Utils::Log;

use Plugins::MusicArtistInfo::Common;

use constant CAN_IMAGEPROXY => (Slim::Utils::Versions->compareVersions($::VERSION, '7.8.0') >= 0);
use constant BASE_URL => 'https://api.discogs.com/';

my $log   = logger('plugin.musicartistinfo');
my $cache = Slim::Utils::Cache->new();

if (!main::SCANNER) {
	require Slim::Utils::Strings;
	
	if (CAN_IMAGEPROXY) {
		require Slim::Web::ImageProxy;
		
		Slim::Web::ImageProxy->registerHandler(
			match => qr/api\.discogs\.com/,
			func  => \&artworkUrl,
		);
	}
}

sub getAlbumCover {
	my ( $class, $client, $cb, $args ) = @_;

	$args->{rawUrl} = 1 unless defined $args->{rawUrl};
	
	my $key = "mai_discogs_albumcover_" . Slim::Utils::Text::ignoreCaseArticles($args->{artist} . $args->{album}, 1);
	
	if (my $cached = $cache->get($key)) {
		$cb->($cached);
		return;
	}

	$class->getAlbumCovers($client, sub {
		my $covers = shift;
		
		my $cover = {};
		
		if ($covers && $covers->{images} && ref $covers->{images} eq 'ARRAY') {
			foreach ( @{$covers->{images}} ) {
				next unless $_->{type} eq 'primary';
				
				$cover = $_;
				last;
			}
		}
		
		$cache->set($key, $cover, 86400);
		$cb->($cover);
	}, $args);
}

sub getAlbumCovers {
	my ( $class, $client, $cb, $args ) = @_;
	
	my $rawUrl = delete $args->{rawUrl} || main::SCANNER || !CAN_IMAGEPROXY;
	
	$class->getAlbum($client, sub {
		my $albumInfo = shift;
		my $result = {};

		if ( $albumInfo->{resource_url} ) {
			_call($albumInfo->{resource_url}, undef, sub {
				my $albumDetails = shift;
				my $result = {};
				
				if ( $albumDetails && (my $images = $albumDetails->{images}) ) {
					if ( ref $images eq 'ARRAY' ) {
						my @images;
						
						foreach ( @$images ) {
							next unless $_->{width} >= 300;
							
							push @images, {
								author => 'Discogs',
								url    => $rawUrl ? $_->{uri} : Slim::Web::ImageProxy::proxiedImage($_->{uri}),
								width  => $_->{width},
								height => $_->{height},
								type   => $rawUrl ? $_->{type} : undef,
							};
							
							$cache->set('150_' . $_->{uri}, $_->{uri150}) if $_->{uri150};
						}
						
						$result->{images} = \@images if @images;
					}
				}
				
				if ( !$result->{images} && !main::SCANNER ) {
					$result->{error} ||= Slim::Utils::Strings::cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND');
				}
				
				$cb->($result);
			});
		}
		else {
			$cb->(main::SCANNER ? undef : {
				error => Slim::Utils::Strings::cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND')
			});
		}	
	}, $args);
}

sub getAlbum {
	my ( $class, $client, $cb, $args ) = @_;

	my $artist = Slim::Utils::Text::ignoreCaseArticles($args->{artist}, 1);
	my $album  = Slim::Utils::Text::ignoreCaseArticles($args->{album}, 1);
	my $albumLC= lc( $args->{album} );
	
	if (!$artist || !$album) {
		$cb->();
		return;
	}

	_call('database/search', {
		type   => 'release',
		artist => $artist,
		title  => $album,
	}, sub {
		my $items = shift;
		
		my $albumInfo;
		
		if ( $items = $items->{results} ) {
			foreach ( @$items ) {
				$_->{title} = Slim::Utils::Unicode::utf8decode($_->{title});
	
				if ( Slim::Utils::Text::ignoreCaseArticles($_->{title}, 1) =~ /\Q$artist\E/i
					&& Slim::Utils::Text::ignoreCaseArticles($_->{title}, 1) =~ /\Q$album\E/i ) {
					$albumInfo = $_;
					last;
				}
			}
		}
		
		$cb->($albumInfo);
	});
}

sub getDiscography {
	my ( $class, $client, $cb, $args ) = @_;
	
	$class->getArtist($client, sub {
		my $artistInfo = shift;
		
		if (!$artistInfo || !$artistInfo->{id}) {
			$cb->();
			return;
		}
		
		_call('artists/' . $artistInfo->{id} . '/releases', {
			per_page => 100
		}, sub {
			my $items = shift;
			my $result = {};
			
			if ( $items && (my $releases = $items->{releases}) ) {
				if ( ref $releases eq 'ARRAY' ) {
					my @releases;
					
					foreach ( @$releases ) {
						next if grep /unofficial|single|45 rpm|promo|\bPAL\b|12"|mini|7"|NTSC|\bEP\b/i, split /, /, $_->{format};
						next if $_->{type} && lc($_->{type}) ne 'master';
						next if $_->{role} && lc($_->{role}) ne 'main';

						push @releases, {
							title  => $_->{title},
							author => 'Discogs',
							image  => Slim::Web::ImageProxy::proxiedImage($_->{thumb}),
							year   => $_->{year},
							resource => $_->{resource_url},
						};
					}
					
					# sort by year descending
					$result->{releases} = [ sort { $b->{year} <=> $a->{year} } @releases ] if @releases;
				}
			}
			
			if ( !$result->{releases} ) {
				$result->{error} ||= Slim::Utils::Strings::cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND');
			}
			
			$cb->($result);
		});
		
	}, $args);
}

sub getArtistPhotos {
	my ( $class, $client, $cb, $args ) = @_;
	
	$class->getArtist($client, sub {
		my $artistInfo = shift;
		
		if (!$artistInfo || !$artistInfo->{id}) {
			$cb->();
			return;
		}
		
		_call('artists/' . $artistInfo->{id}, {}, sub {
			my $items = shift;
			my $result = [];

			if ( $items && (my $images = $items->{images}) ) {
				if ( ref $images eq 'ARRAY' ) {
					$result = [ map {
						{
							author => 'Discogs',
							url    => Slim::Web::ImageProxy::proxiedImage($_->{uri}),
						};
					} @$images ]
				}
			}
			
			$cb->({
				photos => $result
			});
		});
		
	}, $args);
}

sub getArtist {
	my ( $class, $client, $cb, $args ) = @_;

	my $artist = Slim::Utils::Text::ignoreCaseArticles($args->{artist}, 1);
	
	if (!$artist) {
		$cb->();
		return;
	}

	_call('database/search', {
		type => 'artist',
		q    => $artist,
	}, sub {
		my $items = shift;
		
		my $artistInfo;
		
		if ( $items = $items->{results} ) {
			my $alt;
			foreach ( @$items ) {
				$_->{title} = Slim::Utils::Unicode::utf8decode($_->{title});
	
				if ( Slim::Utils::Text::ignoreCaseArticles($_->{title}, 1) =~ /\Q$artist\E/i ) {
					if ($_->{thumb} !~ /record90\.png$/) {
						$artistInfo = $_;
						last;
					}
					else {
						$artistInfo ||= $_;
					}
				}
			}
		}
		
		$cb->($artistInfo);
	});
}

sub _call {
	my ( $resource, $args, $cb ) = @_;
	
	Plugins::MusicArtistInfo::Common->call(
		($resource =~ /^https?:/ ? $resource : (BASE_URL . $resource)) . '?' . join( '&', Plugins::MusicArtistInfo::Common->getQueryString($args) ), 
		$cb,
		{
			cache   => 1,
			expires => 86400,	# force caching - discogs doesn't set the appropriate headers
			headers => Plugins::MusicArtistInfo::Common->getHeaders('discogs')
		}
	);
}


sub artworkUrl { if (!main::SCANNER) {
	my ($url, $spec) = @_;
	
	main::DEBUGLOG && $log->debug("Artwork for $url, $spec");

	if ( Slim::Web::ImageProxy->getRightSize($spec, { 150 => 1 }) ) {
		my $url150 = $cache->get("150_$url");
		$url = $url150 if $url150;
	}
	
	main::DEBUGLOG && $log->debug("Artwork file url is '$url'");

	return $url;
} }

1;