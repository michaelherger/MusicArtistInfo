package Plugins::MusicArtistInfo::AllMusic;

use strict;
use File::Spec::Functions qw(catdir);
use JSON::XS::VersionOneAndTwo;

use FindBin qw($Bin);
use lib catdir($Bin, 'Plugins', 'MusicArtistInfo', 'lib');
use HTML::TreeBuilder;

#use Encode;

use Slim::Networking::SimpleAsyncHTTP;
#use Slim::Utils::Cache;
use Slim::Utils::Log;

use constant BASE_URL         => 'http://www.allmusic.com/';
use constant SEARCH_URL       => BASE_URL . 'search/typeahead/all/%s';
use constant ALBUMSEARCH_URL  => BASE_URL . 'search/albums/%s, %s/all/1';
use constant ARTISTSEARCH_URL => BASE_URL . 'search/artists/%s/all/1';
use constant BIOGRAPHY_URL    => BASE_URL . 'artist/%s/biography';
use constant RELATED_URL      => BASE_URL . 'artist/%s/related';

my $log = logger('plugin.bioalbumreview');

#my $cache = Slim::Utils::Cache->new;

sub getBiography {
	my ( $class, $client, $cb, $args ) = @_;
	
	$class->getArtist($client, sub {
		my $artistInfo = shift;
		
		my $url = ($artistInfo->{url} . '/biography') || sprintf(BIOGRAPHY_URL, $artistInfo->{id});
		
		_get( $client, $cb, {
			url     => $url,
			parseCB => sub {
				my $tree   = shift;
				my $result = {};

				if ( my $bio = $tree->look_down('_tag', 'div', 'itemprop', 'reviewBody') ) {
					# clean up links and images
					foreach ( $bio->look_down('_tag', 'a') ) {
						# make external links absolute
						$_->attr('href', BASE_URL . $_->attr('href')) if $_->attr('href') !~ /^http/;
						# open links in new window
						$_->attr('target', 'allmusic');
					}

					foreach ( $bio->look_down('_tag', 'img', 'class', 'lazy') ) {
						my $src = $_->attr('data-original') || next;
						$_->attr('src', $src);
						$_->attr('data-original', '');
					}

					$result->{bio} = $bio->as_HTML;
					$result->{bio} = Slim::Utils::Unicode::utf8decode_guess($result->{bio});
					$result->{bioText} = Encode::decode( 'utf8', join('\n\n', map { 
						$_->as_trimmed_text;
					} $bio->content_list) );
				}
				
				my $author = $tree->look_down('_tag', 'h2', 'class', 'headline');
				$result->{author} = $author->as_trimmed_text if $author;
				
				return $result;
			} 
		} );
	}, $args);
}

sub getArtistPhotos {
	my ( $class, $client, $cb, $args ) = @_;
	
	$class->getArtist($client, sub {
		my $artistInfo = shift;
		
		my $url = ($artistInfo->{url} . '/biography') || sprintf(BIOGRAPHY_URL, $artistInfo->{id});
		
		_get( $client, $cb, {
			url     => $url,
			parseCB => sub {
				my $tree   = shift;
				my $result = [];

				foreach ( $tree->look_down('_tag', 'div', 'class', 'media-gallery-image thumbnail') ) {
					my $img = eval { from_json( Encode::encode( 'utf8', $_->attr('data-gallery') ) ) };

					if ($@) {
						logError(@$);
					}
					elsif ($img) {
						push @$result, {
							author => $img->{author},
							url    => $img->{url},
							height => $img->{height},
							width  => $img->{width},
						};
					}
				}
				
				return $result;
			} 
		} );
	}, $args);
}

sub getArtistDetails {
	my ( $class, $client, $cb, $args ) = @_;
	
	$class->getArtist($client, sub {
		my $artistInfo = shift;
		
		my $url = ($artistInfo->{url} . '/biography') || sprintf(BIOGRAPHY_URL, $artistInfo->{id});
		
		_get( $client, $cb, {
			url     => $url,
			parseCB => sub {
				my $tree   = shift;
				my $result = [];
				
				my $details = $tree->look_down('_tag', 'div', 'class', 'sidebar');

				foreach ( 'active-dates', 'birth', 'genre', 'styles', 'aliases', 'member-of' ) {
					if ( my $item = $details->look_down('_tag', 'div', 'class', $_) ) {
						my $title = $item->look_down('_tag', 'h4');
						my $value = $item->look_down('_tag', 'div', 'class', undef);

						next unless $title && $value;

						if ( /genre|styles|member/ ) {
							# XXX - link to genre/artist pages?
							my $values = [];
							foreach ( $value->look_down('_tag', 'a') ) {
								push @$values, $_->as_trimmed_text;
							}
							
							$value = $values if scalar @$values;
						}
						elsif ( /aliases/ ) {
							my $values = [];
							foreach ( $value->look_down('_tag', 'div', sub { !$_[0]->descendents }) ) {
								push @$values, $_->as_trimmed_text;
							}
							
							$value = $values if scalar @$values;
						}
						
						push @$result, {
							$title->as_trimmed_text => ref $value eq 'ARRAY' ? $value : $value->as_trimmed_text,
						} if $title && $value;
					}
				}
				
				return $result;
			} 
		} );
	}, $args);
}

sub getRelatedArtists {
	my ( $class, $client, $cb, $args ) = @_;
	
	$class->getArtist($client, sub {
		my $artistInfo = shift;
		
		my $url = ($artistInfo->{url} . '/related') || sprintf(RELATED_URL, $artistInfo->{id});
		
		_get( $client, $cb, {
			url     => $url,
			parseCB => sub {
				my $tree   = shift;
				my $result = [];
				
				foreach ( 'similars', 'influencers', 'followers', 'associatedwith', 'collaboratorwith' ) {
					my $related = $tree->look_down('_tag', 'section', 'class', "related $_") || next;
					my $title = $related->look_down('_tag', 'h2') || next;

					my $items = $related->look_down("_tag", "ul") || next;

					push @$result, {
						$title->as_trimmed_text => [ map {
							_parseArtistInfo($_);
						} $items->content_list ]
					};
				}
				
				return $result;
			} 
		} );
	}, $args);
}

sub getArtist {
	my ( $class, $client, $cb, $args ) = @_;
	
	my $artist = $args->{artist};
	
	if (!$artist) {
		$cb->();
		return;
	}
	
	$class->searchArtists($client, sub {
		my $items = shift;
		
		my $artistInfo;
		
		foreach (@$items) {
			# TODO - sanity check input, "smart matching" bjork/björk etc.
			if ( $_->{name} =~ /$artist/i ) {
				$artistInfo = $_;
				last;
			}
		}
		
		$cb->($artistInfo);
	}, $args)
}

sub searchArtists {
	my ( $class, $client, $cb, $args ) = @_;
	
	my $url = sprintf(ARTISTSEARCH_URL, $args->{artist});

	_get( $client, $cb, {
		url     => $url,
		parseCB => sub { 
			my $tree   = shift;
			my $result = [];
			
			my $results = $tree->look_down("_tag", "ul");

			foreach ($results->content_list) {
				my $artist = $_->look_down('_tag', 'div', 'class', 'name') || next;
				
				my $artistData = _parseArtistInfo($artist);
				
				push @$result, $artistData if $artistData->{url};
			}

			return $result;
		}
	} );
}

sub searchAlbums {
	my ( $class, $client, $cb, $args ) = @_;
	
	my $url = sprintf(ALBUMSEARCH_URL, $args->{artist}, $args->{album});

	_get( $client, $cb, {
		url     => $url,
		parseCB => sub { 
			my $tree   = shift;
			my $result = [];
			
			my $results = $tree->look_down("_tag", "ul");

			foreach ($results->content_list) {
				my $title  = $_->look_down('_tag', 'div', 'class', 'title') || next;
				my $url    = $title->look_down('_tag', 'a') || next;
				my $artist = $_->look_down('_tag', 'div', 'class', 'artist') || next;

				my $albumData = {
					name => $title->as_text,
					url  => $url->attr('href'),
					artist => _parseArtistInfo($artist),
				};
				
				if ( my $year = $_->look_down('_tag', 'div', 'class', 'year') ) {
					$albumData->{year} = $year->as_text + 0;
				}
				
				push @$result, $albumData;
			}

			return $result;
		}
	} );
}

sub _parseArtistInfo {
	my $data = shift;
	
	my $artistInfo = {
		name => $data->as_text,
	};
	
	if ( my $url = $data->look_down('_tag', 'a') ) {
		$artistInfo->{url} = $url->attr('href');
		
		my $id = _getIdFromUrl($artistInfo->{url});
		$artistInfo->{id} = $id if $id; 
	}
				
	if ( my $decades = $_->look_down('_tag', 'div', 'class', 'decades') ) {
		$artistInfo->{decades} = $decades->as_trimmed_text;
	}
	
	return $artistInfo;
}

sub _getIdFromUrl {
	$_[0] =~ /\b(\w+)$/;
	return $1;
}

sub _get {
	my ( $client, $cb, $args ) = @_;
	
	my $url = $args->{url} || return;
	my $parseCB = $args->{parseCB};

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;
			
			my $result;
			my $error;

			#warn Data::Dump::dump($response->content);
			
			if ( $response->headers->content_type =~ /html/ ) {
				my $tree = HTML::TreeBuilder->new;
				$tree->no_expand_entities(1);
				$tree->ignore_unknown(0);
				$tree->parse_content( $response->content );
#				$tree->parse_content( Encode::decode( 'utf8', $response->content) );

				$result = $parseCB->($tree) if $parseCB;
			}
			
			if (!$result) {
				$result = { error => 'Error: Invalid data' };
				$log->error($result->{error});
			}

#			main::DEBUGLOG && $log->debug(Data::Dump::dump($result));
			
			$cb->($result);
		},
		sub {
			$log->warn("error: $_[1]");
			$cb->({ error => 'Unknown error: ' . $_[1] });
		},
		{
			client  => $client,
			cache   => 1,
			expires => 86400,		# set expiration, as allmusic doesn't provide it
			timeout => 30,
		},
	)->get($url);
}

1;