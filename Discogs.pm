package Plugins::MusicArtistInfo::Discogs;

use strict;
use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape uri_escape_utf8);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string cstring);
use Slim::Web::ImageProxy qw(proxiedImage);

use constant CAN_IMAGEPROXY => (Slim::Utils::Versions->compareVersions($::VERSION, '7.8.0') >= 0);
use constant BASE_URL => 'http://api.discogs.com/';

my $log   = logger('plugin.musicartistinfo');
my $cache = Slim::Utils::Cache->new();

if (CAN_IMAGEPROXY) {
	Slim::Web::ImageProxy->registerHandler(
		match => qr/api\.discogs\.com/,
		func  => \&artworkUrl,
	);
}

sub getAlbumCover {
	my ( $class, $client, $cb, $args ) = @_;
	
	if (!CAN_IMAGEPROXY) {
		$cb->();
	}
	
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
								url    => proxiedImage($_->{uri}),
								width  => $_->{width},
								height => $_->{height},
							};
							
							$cache->set('150_' . $_->{uri}, $_->{uri150}) if $_->{uri150};
						}
						
						$result->{images} = \@images if @images;
					}
				}
				
				if ( !$result->{images} ) {
					$result->{error} ||= cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND');
				}
				
				$cb->($result);
			});
		}
		else {
			$cb->({
				error => cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND')
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
	
				if ( Slim::Utils::Text::ignoreCaseArticles($_->{title}, 1) =~ /$artist/i
					&& Slim::Utils::Text::ignoreCaseArticles($_->{title}, 1) =~ /$album/i ) {
					$albumInfo = $_;
					last;
				}
			}
		}
		
		$cb->($albumInfo);
	});
}

=pod
sub getDiscography {
	my ( $class, $client, $cb, $args ) = @_;
	
	my $artist = Slim::Utils::Text::ignoreCaseArticles($args->{artist}, 1);
	
	if (!$artist) {
		$cb->();
		return;
	}
	
	$class->getArtist($client, sub {
		my $artistInfo = shift;
		
		warn Data::Dump::dump($artistInfo);
		
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

warn Data::Dump::dump($_);						
						push @releases, {
							title  => $_->{title},
							author => 'Discogs',
							image  => proxiedImage($_->{thumb}),
#							label  => $_->{label},
							year   => $_->{year},
							resource => $_->{resource_url},
						};
					}
					
					# sort by year descending
					$result->{releases} = [ sort { $b->{year} <=> $a->{year} } @releases ] if @releases;
				}
			}
			
			if ( !$result->{releases} ) {
				$result->{error} ||= cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND');
			}
			
			$cb->($result);
		});
		
	}, $args);

=pod
	_call('database/search', {
		type   => 'master',
		artist => $artist,
		per_page => 100,
	}, sub {
		my $items = shift;
		my $result = {};
		
		if ( $items && (my $releases = $items->{results}) ) {
			if ( ref $releases eq 'ARRAY' ) {
				my @releases;
				
				foreach ( @$releases ) {
					next if grep /unofficial|single|45 rpm|promo|\bPAL\b|12"|mini|7"|NTSC|\bEP\b/i, @{$_->{format}};
					
					push @releases, {
						title  => $_->{title},
						author => 'Discogs',
						image  => proxiedImage($_->{thumb}),
						label  => $_->{label},
						year   => $_->{year},
						resource => $_->{resource_url},
					};
				}
				
				# sort by year descending
				$result->{releases} = [ sort { $b->{year} <=> $a->{year} }@releases ] if @releases;
			}
		}
		
		if ( !$result->{releases} ) {
			$result->{error} ||= cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND');
		}
		
		$cb->($result);
	});
=cut
=pod
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
	
				if ( Slim::Utils::Text::ignoreCaseArticles($_->{title}, 1) =~ /$artist/i ) {
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
=cut

sub _call {
	my ( $resource, $args, $cb ) = @_;
	
	$args ||= {};
	
	my @query;
	while (my ($k, $v) = each %$args) {
		next if $k =~ /^_/;		# ignore keys starting with an underscore
		
		if (ref $v eq 'ARRAY') {
			foreach (@$v) {
				push @query, $k . '=' . uri_escape_utf8($_);
			}
		}
		else {
			push @query, $k . '=' . uri_escape_utf8($v);
		}
	}

	my $params = join('&', @query);
	my $url = $resource =~ /^https?:/ ? $resource : (BASE_URL . $resource);

	main::INFOLOG && $log->is_info && $log->info("Async API call: GET $url?$params");
	
	my $cb2 = sub {
		my $response = shift;
		
		main::DEBUGLOG && $log->is_debug && $response->code !~ /2\d\d/ && $log->debug(Data::Dump::dump($response, @_));
		my $result = eval { from_json( $response->content ) };
	
		$result ||= {};
		
		if ($@) {
			 $log->error($@);
			 $result->{error} = $@;
		}

		main::DEBUGLOG && $log->is_debug && warn Data::Dump::dump($result);
			
		$cb->($result);
	};
	
	Slim::Networking::SimpleAsyncHTTP->new( 
		$cb2, 
		$cb2, 
		{
			timeout => 15,
			cache   => 1,
			expires => 86400,	# force caching - discogs doesn't set the appropriate headers
		}
	)->get($url . '?' . $params);
}


sub artworkUrl {
	my ($url, $spec) = @_;
	
	main::DEBUGLOG && $log->debug("Artwork for $url, $spec");

	if ( Slim::Web::ImageProxy->getRightSize($spec, { 150 => 1 }) ) {
		my $url150 = $cache->get("150_$url");
		$url = $url150 if $url150;
	}
	
	main::DEBUGLOG && $log->debug("Artwork file url is '$url'");

	return $url;
}

1;