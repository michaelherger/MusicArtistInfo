package Plugins::MusicArtistInfo::AllMusic;

use strict;
use File::Spec::Functions qw(catdir);
use JSON::XS::VersionOneAndTwo;

use Encode;
use FindBin qw($Bin);
use lib catdir($Bin, 'Plugins', 'MusicArtistInfo', 'lib');
use HTML::Entities;
use HTML::TreeBuilder;
use URI::Escape;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string cstring);

use constant BASE_URL         => 'http://www.allmusic.com/';
use constant SEARCH_URL       => BASE_URL . 'search/typeahead/all/%s';
use constant ALBUMSEARCH_URL  => BASE_URL . 'search/albums/%s%%2C%%20%s';
use constant ARTISTSEARCH_URL => BASE_URL . 'search/artists/%s';
use constant BIOGRAPHY_URL    => BASE_URL . 'artist/%s/biography';
use constant RELATED_URL      => BASE_URL . 'artist/%s/related';
use constant ALBUMREVIEW_URL  => BASE_URL . 'album/%s';
use constant ALBUMCREDITS_URL => BASE_URL . ALBUMREVIEW_URL . '/credits';

my $log = logger('plugin.musicartistinfo');

sub getBiography {
	my ( $class, $client, $cb, $args ) = @_;

	my $getBiographyCB = sub {
		my $url = _getBioUrl(shift);

		_get( $client, $cb, {
			url     => $url,
			parseCB => sub {
				my $tree   = shift;
				my $result = {};

				main::DEBUGLOG && $log->is_debug && $tree->dump;

				if ( my $bio = $tree->look_down('_tag', 'section', 'class', 'biography') ) {
					main::DEBUGLOG && $log->is_debug && $log->debug('Found biography - parsing');

					$bio = _cleanupLinksAndImages($bio);

					$result->{bio} = _decodeHTML($bio->as_HTML);
					$result->{bioText} = Encode::decode( 'utf8', join('\n\n', map {
						$_->as_trimmed_text;
					} $bio->content_list) );

					$result->{bio} || $log->warn('Failed to find biography for ' . $url);
				}

				my $author = $tree->look_down('_tag', 'h2', 'class', 'headline');
				$result->{author} = $author->as_trimmed_text if $author;

				return $result;
			}
		} );
	};

	if ( $args->{url} || $args->{id} ) {
		$getBiographyCB->( $args );
	}
	else {
		$class->getArtist($client, sub {
			$getBiographyCB->( shift );
		}, $args);
	}
}

sub getArtistPhotos {
	my ( $class, $client, $cb, $args ) = @_;

	my $getArtistPhotosCB = sub {
		my $url = _getBioUrl(shift);

		$url =~ s|/biography.*||;
		_get( $client, $cb, {
			url     => $url,
			parseCB => sub {
				my $tree = shift;

				my $result = [];

				if ($tree->as_HTML =~ /imageGallery.*?(\[.*?\])/) {
					my $imageGallery = eval { from_json($1) };

					if (!$@ && ref $imageGallery && ref $imageGallery eq 'ARRAY' && scalar @$imageGallery) {
						$result = [ map {
							{
								author => $_->{author} || 'AllMusic.com',
								url    => $_->{url},
								width  => $_->{width},
								height => $_->{height}
							}
						} @$imageGallery ];
					}
				}

				return {
					photos => $result
				};
			}
		} );
	};

	if ( $args->{url} || $args->{id} ) {
		$getArtistPhotosCB->( $args );
	}
	else {
		$class->getArtist($client, sub {
			$getArtistPhotosCB->( shift );
		}, $args);
	}
}

sub getArtistDetails {
	my ( $class, $client, $cb, $args ) = @_;

	my $getArtistDetailsCB = sub {
		my $url = _getBioUrl(shift);

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

						if ( /genre|styles/ ) {
							# XXX - link to genre/artist pages?
							my $values = [];
							foreach ( $value->look_down('_tag', 'a') ) {
								push @$values, Encode::decode('utf8', $_->as_trimmed_text);
							}

							$value = $values if scalar @$values;
						}
						elsif ( /member/ ) {
							my $values = [];
							foreach ( $value->look_down('_tag', 'a') ) {
								push @$values, {
									HTML::Entities::decode($_->as_trimmed_text) => $_->attr('href')
								};
							}

							$value = $values if scalar @$values;
						}
						elsif ( /aliases/ ) {
							my $values = [];
							foreach ( $value->look_down('_tag', 'div', sub { !$_[0]->descendents }) ) {
								push @$values, Encode::decode('utf8', $_->as_trimmed_text);
							}

							$value = $values if scalar @$values;
						}

						push @$result, {
							Encode::decode('utf8', $title->as_trimmed_text) => ref $value eq 'ARRAY' ? $value : Encode::decode('utf8', $value->as_trimmed_text),
						} if $title && $value;
					}
				}

				return {
					items => $result
				};
			}
		} );
	};

	if ( $args->{url} || $args->{id} ) {
		$getArtistDetailsCB->( $args );
	}
	else {
		$class->getArtist($client, sub {
			$getArtistDetailsCB->( shift );
		}, $args);
	}
}

sub getRelatedArtists {
	my ( $class, $client, $cb, $args ) = @_;

	my $getRelatedArtistsCB = sub {
		my $url = $_[0]->{url} ? ($_[0]->{url} . '/related') : sprintf(RELATED_URL, $_[0]->{id});

		_get( $client, $cb, {
			url     => $url,
			parseCB => sub {
				my $tree   = shift;
				my $result = [];

				foreach ( 'similars', 'influencers', 'followers', 'associatedwith', 'collaboratorwith' ) {
					my $related = $tree->look_down('_tag', 'section', 'class', "related $_") || next;
					my $title = $related->look_down('_tag', 'h3') || next;
					my $items = $related->look_down("_tag", "ul") || next;

					push @$result, {
						$title->as_trimmed_text => [ map {
							_parseArtistInfo($_);
						} $items->content_list ]
					};
				}

				return {
					items => $result
				};
			}
		} );
	};

	if ( $args->{url} || $args->{id} ) {
		$getRelatedArtistsCB->( $args );
	}
	else {
		$class->getArtist($client, sub {
			$getRelatedArtistsCB->( shift );
		}, $args);
	}
}

sub getArtist {
	my ( $class, $client, $cb, $args ) = @_;

	my $artist = Slim::Utils::Text::ignoreCaseArticles($args->{artist}, 1);
	my $artistLC = lc($args->{artist});

	if (!$artist) {
		$cb->();
		return;
	}

	my $artist2 = $args->{artist};
	$artist2 =~ s/&/and/g;
	$artist2 = Slim::Utils::Text::ignoreCaseArticles($artist2, 1);

	$class->searchArtists($client, sub {
		my $items = shift;

		if (!$items || ref $items ne 'ARRAY') {
			$cb->();
			return;
		}

		my $artistInfo;

		foreach (@$items) {
			my $current = lc( Slim::Utils::Unicode::utf8decode($_->{name}) );

			# immediately stop if names are identical
			if ( $current eq $artist || $current eq $artistLC || $current eq $artist2 ) {
				$artistInfo = $_;
				last;
			}

			$current = Slim::Utils::Text::ignoreCaseArticles($current, 1);

			# alternatively pick first to partially match the name
			if ( !$artistInfo && $current =~ /(\Q$artist\E|\Q$artist2\E)/i ) {
				$artistInfo = $_;
			}
		}

		$cb->($artistInfo);
	}, $args)
}

sub searchArtists {
	my ( $class, $client, $cb, $args ) = @_;

	my $url = sprintf(ARTISTSEARCH_URL, URI::Escape::uri_escape_utf8($args->{artist}));

	_get( $client, $cb, {
		url     => $url,
		parseCB => sub {
			my $tree   = shift;
			my $result = [];

			my $results = $tree->look_down("_tag" => "ul", "class" => "search-results");

			return $result unless $results;

			foreach ($results->content_list) {
				my $artist = $_->look_down('_tag', 'div', 'class', 'name') || next;

				my $artistData = _parseArtistInfo($artist);

				push @$result, $artistData if $artistData->{url};
			}

			return $result;
		}
	} );
}

sub getAlbumReview {
	my ( $class, $client, $cb, $args ) = @_;

	my $getAlbumReviewCB = sub {
		my $url = _getAlbumReviewUrl(shift);

		_get( $client, $cb, {
			url     => $url,
			parseCB => sub {
				my $tree   = shift;
				my $result = {};

				main::DEBUGLOG && $log->is_debug && $tree->dump;

				if ( my $review = $tree->look_down('_tag', 'script', 'type', 'application/ld+json') ) {
					main::DEBUGLOG && $log->is_debug && $log->debug('Found reviewBody - parsing');

					$review = $review->as_HTML;
					$review =~ s/.*?<script.*?>(.*)<\/script.*/$1/sig;

					$review = eval { from_json($review) };

					$log->error("Failed to parse $url: $@") if $@;

					if ($review && ref $review) {
						$result->{review} = $result->{reviewText} = $review->{review}->{reviewBody};
						$result->{author} = $review->{review}->{name};
						$result->{image} = $review->{image};
					}
				}
				elsif ( my $review = $tree->look_down('_tag', 'div', 'itemprop', 'reviewBody') ) {

					main::DEBUGLOG && $log->is_debug && $log->debug('Found reviewBody - parsing');

					$review = _cleanupLinksAndImages($review);

					$result->{review} = _decodeHTML($review->as_HTML);
					$result->{reviewText} = Encode::decode( 'utf8', join('\n\n', map {
						$_->as_trimmed_text;
					} $review->content_list) );

					$result->{review} || $log->warn('Failed to find album review for ' . $url);
				}

				if (!$result->{author}) {
					my $author = $tree->look_down('_tag', 'h4', 'class', 'review-author headline');
					$result->{author} = $author->as_trimmed_text if $author;
				}

				if (!$result->{image}) {
					my $cover = $tree->look_down('_tag', 'div', 'class', 'album-contain');
					if ( $cover && (my $img = $cover->look_down('_tag', 'img')) ) {
						$result->{image} = _makeLinkAbsolute($img->attr('src'));
					}
				}

				return $result;
			}
		} );
	};

	if ( $args->{url} || $args->{id} ) {
		$getAlbumReviewCB->( $args );
	}
	else {
		$class->getAlbum($client, sub {
			$getAlbumReviewCB->( shift );
		}, $args);
	}
}

sub getAlbumDetails {
	my ( $class, $client, $cb, $args ) = @_;

	my $getAlbumDetailsCB = sub {
		my $url = _getAlbumReviewUrl(shift);

		_get( $client, $cb, {
			url     => $url,
			parseCB => sub {
				my $tree   = shift;
				my $result = [];

				if ( my $details = $tree->look_down('_tag', 'section', 'class', 'basic-info') ) {
					foreach ( 'release-date', 'recording-date', 'duration', 'genre', 'styles' ) {
						if ( my $item = $details->look_down('_tag', 'div', 'class', $_) ) {
							my $title = $item->look_down('_tag', 'h4');
							my $value = $item->look_down('_tag', 'div', 'class', undef) || $item->look_down('_tag', 'span');

							next unless $title && $value;

							if ( /genre|styles/ ) {
								# XXX - link to genre/artist pages?
								my $values = [];
								foreach ( $value->look_down('_tag', 'a') ) {
									push @$values, $_->as_trimmed_text;
								}

								$value = $values if scalar @$values;
							}

							push @$result, {
								$title->as_trimmed_text => ref $value eq 'ARRAY' ? $value : $value->as_trimmed_text,
							} if $title && $value;
						}
					}
				}

				if ( my $item = $tree->look_down('_tag', 'section', 'class', 'moods') ) {
					my $title = $item->look_down('_tag', 'h4');
					my $value = $item->look_down('_tag', 'div', 'class', undef);

					if ( $title && $value ) {
						my $values = [];
						foreach ( $value->look_down('_tag', 'a') ) {
							push @$values, $_->as_trimmed_text;
						}

						$value = $values if scalar @$values;
					}

					push @$result, {
						$title->as_trimmed_text => ref $value eq 'ARRAY' ? $value : $value->as_trimmed_text,
					} if $title && $value;
				}

				return {
					items => $result
				};
			}
		} );
	};

	if ( $args->{url} || $args->{id} ) {
		$getAlbumDetailsCB->( $args );
	}
	else {
		$class->getAlbum($client, sub {
			$getAlbumDetailsCB->( shift );
		}, $args);
	}
}

sub getAlbumCovers {
	my ( $class, $client, $cb, $args ) = @_;

	my $getAlbumCoverCB = sub {
		my $url = _getAlbumReviewUrl(shift);

		_get( $client, $cb, {
			url     => $url,
			parseCB => sub {
				my $tree   = shift;
				my $result = {};

				#main::DEBUGLOG && $log->is_debug && $tree->dump;

				if ( my $cover = $tree->look_down('_tag', 'img', 'class', 'media-gallery-image') ) {
					#main::DEBUGLOG && $log->is_debug && $cover->dump;
					my $img = eval { from_json( $cover->attr('data-lightbox') ) };

					if ( $@ ) {
						# sometimes we don't have a data-lightbox - use the image shown instead
						if ($img = $cover->attr('src')) {
							my ($size) = $img =~ /(?:jpe?g|png)_(\d+)/i;
							$result->{images} = [ {
								author => 'AllMusic.com',
								url    => $img,
								width  => $size,
							} ];
						}
						else {
							$result->{error} = $@;
						}
					}
					elsif ( $img && $img->{image} ) {
						$result->{images} = [ {
							author => $img->{image}->{author} || 'AllMusic.com',
							url    => _makeLinkAbsolute($img->{image}->{url}),
							height => $img->{image}->{height},
							width  => $img->{image}->{width},
						} ];
					}
				}

				if ( !$result->{images} ) {
					$result->{error} ||= cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND');
				}

				return $result;
			}
		} );
	};

	if ( $args->{url} || $args->{id} ) {
		$getAlbumCoverCB->( $args );
	}
	else {
		$class->getAlbum($client, sub {
			$getAlbumCoverCB->( shift );
		}, $args);
	}
}

sub getAlbumCredits {
	my ( $class, $client, $cb, $args ) = @_;

	my $getAlbumDetailsCB = sub {
		my $url = $_[0]->{url} ? ($_[0]->{url} . '/credits') : sprintf(ALBUMCREDITS_URL, $_[0]->{id});

		_get( $client, $cb, {
			url     => $url,
			parseCB => sub {
				my $tree   = shift;
				my $result = [];

				if ( my $credits = $tree->look_down('_tag', 'table') ) {
					foreach ($credits->content_list) {
						my $artist = $_->look_down('_tag', 'td', 'class', 'artist') || next;

						my $artistData = _parseArtistInfo($artist);

						if ( my $credit = $_->look_down('_tag', 'td', 'class', 'credit') ) {
							$artistData->{credit} = $credit->as_trimmed_text;
						}

						push @$result, $artistData if $artistData->{name};
					}
				}

				return {
					items => $result
				};
			}
		} );
	};

	if ( $args->{url} || $args->{id} ) {
		$getAlbumDetailsCB->( $args );
	}
	else {
		$class->getAlbum($client, sub {
			$getAlbumDetailsCB->( shift );
		}, $args);
	}
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

	my $artist2 = $args->{artist};
	$artist2 =~ s/&/and/g;
	$artist2 = Slim::Utils::Text::ignoreCaseArticles($artist2, 1);

	$class->searchAlbums($client, sub {
		my $items = shift;

		if (!$items || ref $items ne 'ARRAY') {
			$cb->();
			return;
		}

		my $albumInfo;

		foreach (@$items) {
			$_->{name} = Slim::Utils::Unicode::utf8decode($_->{name});
			$_->{artist}->{name} = Slim::Utils::Unicode::utf8decode($_->{artist}->{name});
			my $artistName = Slim::Utils::Text::ignoreCaseArticles($_->{artist}->{name}, 1);

			if ( $artistName =~ /\Q$artist\E/i || $artistName =~ /\Q$artist2\E/i ) {
				if ( lc($_->{name}) eq $albumLC ) {
					$albumInfo = $_;
					last;
				}

				if ( !$albumInfo && Slim::Utils::Text::ignoreCaseArticles($_->{name}, 1) =~ /\Q$album\E/i ) {
					$albumInfo = $_;
				}
			}
		}

		$cb->($albumInfo);
	}, $args)
}

sub searchAlbums {
	my ( $class, $client, $cb, $args ) = @_;

	my $url = sprintf(
		ALBUMSEARCH_URL,
		URI::Escape::uri_escape_utf8($args->{artist}),
		URI::Escape::uri_escape_utf8($args->{album})
	);

	_get( $client, $cb, {
		url     => $url,
		parseCB => sub {
			my $tree   = shift;
			my $result = [];

			if ( my $results = $tree->look_down("_tag" => "ul", "class" => "search-results") ) {
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
			}

			return $result;
		}
	} );
}

sub _cleanupLinksAndImages {
	my $tree = shift;

	# clean up links and images
	foreach ( $tree->look_down('_tag', 'a') ) {
		# make external links absolute
		$_->attr('href', _makeLinkAbsolute($_->attr('href')));
		# open links in new window
		$_->attr('target', 'allmusic');
	}

	foreach ( $tree->look_down('_tag', 'img', 'class', 'lazy') ) {
		my $src = $_->attr('data-original') || next;
		$_->attr('src', _makeLinkAbsolute($src));
		$_->attr('data-original', '');
		$_->attr('onerror', "this.style.display='none'");
	}

	return $tree;
}

sub _makeLinkAbsolute {
	my $src = shift;

	if ($src !~ /^http/) {
		$src =~ s/^\///;		# remove leading slash to prevent double slashes
		$src = BASE_URL . $src;
	}

	return $src;
}

sub _parseArtistInfo {
	my $data = shift;

	my $artistInfo = {
		name => Encode::decode('utf8', $data->as_text),
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

sub _getBioUrl {
	return $_[0]->{url} ? ($_[0]->{url} . '/biography') : sprintf(BIOGRAPHY_URL, $_[0]->{id});
}

sub _getAlbumReviewUrl {
	return $_[0]->{url} ? $_[0]->{url} : sprintf(ALBUMREVIEW_URL, $_[0]->{id});
}

sub _getIdFromUrl {
	$_[0] =~ /\b(\w+)$/;
	return $1;
}

sub _decodeHTML {
	return Encode::decode(
		'utf8',
		HTML::Entities::decode(shift)
	);
}

sub _get {
	my ( $client, $cb, $args ) = @_;

	main::INFOLOG && $log->info('Getting ' . $args->{url});

	my $url = $args->{url} || return;
	my $parseCB = $args->{parseCB};

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;

			my $result;
			my $error;

			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($response->content));

			if ( $response->headers->content_type =~ /html/ && $response->content ) {
				my $tree = HTML::TreeBuilder->new;
				$tree->ignore_unknown(0);		# allmusic.com uses unknown "section" tag
				$tree->parse_content( $response->content );

				$result = $parseCB->($tree) if $parseCB;
			}

			if (!$result) {
				$result = { error => 'Error: Invalid data' };
				$log->error($result->{error});
			}

			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($result));

			$cb->($result);
		},
		sub {
			my $response = shift;
			my $error    = shift || '';

			my $item = {
				error => 'Unknown error',
			};

			if ($response->code == 404 || $error =~ /404/) {
				$item = {
					error => cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND'),
				};
			}
			else {
				main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($response));

				$log->warn("error: $error");
				$item = { error => 'Unknown error: ' . $error }
			}

			$cb->($item);
		},
		{
			client  => $client,
			cache   => 1,
			expires => 86400,		# set expiration, as allmusic doesn't provide it
			timeout => 15,
		},
	)->get($url);
}

1;