package Plugins::MusicArtistInfo::MusicBrainz;

use strict;
use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape uri_escape_utf8);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;

my $log   = logger('plugin.musicartistinfo');

use constant BASE_URL => 'http://musicbrainz.org/ws/2/';
use constant ART_BASE_URL => 'http://coverartarchive.org/release-group/%s/%s';

sub getDiscography {
	my ( $class, $client, $cb, $args ) = @_;

	my $getDiscographyCb = sub {
		my $mbid = shift;

		_call("release-group", {
			artist => $mbid,
			type   => 'album',
			limit  => 100,
		}, sub {
			my $artistInfo = shift;
			
			my $items = [];
			
			if ( my $releases = $artistInfo->{'release-groups'} ) {
				foreach ( @$releases ) {
					next unless $_->{'first-release-date'};

					my $title = $_->{title};
					$title .= ' (' . $_->{disambiguation} . ')' if $_->{disambiguation};
					
					push @$items, {
						title => $title,
						mbid  => $_->{id},
						cover => sprintf(ART_BASE_URL, $_->{id}, 'front'),
						date => $_->{'first-release-date'},
					};
				}
			}
			
			$cb->($items);
		});
	};
	
	if ($args->{mbid}) {
		$getDiscographyCb->($args->{mbid});
	}
	else {
		$class->getArtist($client, sub {
			my $artistInfo = shift;
			
			if ($artistInfo && $artistInfo->{id}) {
				$getDiscographyCb->($artistInfo->{id});
			}
			else {
				$cb->();
			}
		}, $args);
	}
}

sub getAlbumCovers {
	my ( $class, $client, $cb, $args ) = @_;

	my $getCoversCb = sub {
		my $mbid = shift;

		_call(sprintf(ART_BASE_URL, $mbid), {}, sub {
			my $coverInfo = shift;
			my $result = {};

			if (my $images = $coverInfo->{images}) {
				if ( ref $images eq 'ARRAY' ) {
					my @images;
					
					foreach ( @$images ) {
						push @images, {
							author => 'MusicBrainz',
							url    => $_->{image},
							# width  => $_->{width},
							# height => $_->{height},
							# type   => $rawUrl ? $_->{type} : undef,
						};
					}
					
					$result->{images} = \@images if @images;
				}
			}

			if ( !$result->{images} && !main::SCANNER ) {
				$result->{error} ||= Slim::Utils::Strings::cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND');
			}
			
			$cb->($result);
		});
	};
	
	if ($args->{mbid}) {
		$getCoversCb->($args->{mbid});
	}
	else {
		$class->getAlbum($client, sub {
			my $albumInfo = shift;
			
			if ($albumInfo && $albumInfo->{id}) {
				$getCoversCb->($albumInfo->{id});
			}
			else {
				$cb->();
			}
		}, $args);
	}
}

sub getArtist {
	my ( $class, $client, $cb, $args ) = @_;

	my $artist = Slim::Utils::Text::ignoreCaseArticles($args->{artist}, 1);
	
	if (!$artist) {
		$cb->();
		return;
	}

	_call('artist', {
		query => $artist,
	}, sub {
		my $items = shift;
		
		my $artistInfo;
		
		if ( $items = $items->{artists} ) {
			# some fuzzyness to find the correct artist (test eg. "Adele"):
			# - pick artists whose name matches or the score is >= 80
			# - sort by the "amount of information" available to guess a significance...
			# - pick top item
			($artistInfo) = sort {
				keys %$b <=> keys %$a
			} grep {
				my $name = Slim::Utils::Unicode::utf8decode($_->{name});
	
				$_->{score} >= 80 && Slim::Utils::Text::ignoreCaseArticles($name, 1) =~ /\Q$artist\E/i;
			} @$items;
		}
		
		$cb->($artistInfo);
	});
}

sub getAlbum {
	my ( $class, $client, $cb, $args ) = @_;

	my $artist = Slim::Utils::Text::ignoreCaseArticles($args->{artist}, 1);
	my $album = Slim::Utils::Text::ignoreCaseArticles($args->{album}, 1);
	
	if (!$artist || !$album) {
		$cb->();
		return;
	}

	_call('release-group', {
		query => "release:\"$album\" AND artist:\"$artist\"",
	}, sub {
		my $items = shift;
		my $albumInfo;
	
		if ( $items->{'release-groups'} ) {
			$albumInfo = shift @{$items->{'release-groups'}}
		}
		
		$cb->($albumInfo);
	});
}


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

	my $params = join('&', sort { $a cmp $b } @query, 'fmt=json');
	my $url = $resource =~ /^https?:/ ? $resource : (BASE_URL . $resource);

	main::INFOLOG && $log->is_info && $log->info("Async API call: GET $url?$params");
	
	my $cb2 = sub {
		my $response = shift;
		
		main::DEBUGLOG && $log->is_debug && $response->code !~ /2\d\d/ && $log->debug(_debug(Data::Dump::dump($response, @_)));
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
#			cache   => 1,
#			expires => 86400,
		}
	)->get($url . '?' . $params);
}

1;