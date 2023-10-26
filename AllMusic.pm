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

use Plugins::MusicArtistInfo::AllMusic::Common qw(BASE_URL ALBUMSEARCH_URL);

use constant SEARCH_URL       => BASE_URL . 'search/typeahead/all/%s';
use constant ARTISTSEARCH_URL => BASE_URL . 'search/artists/%s';
use constant ARTIST_URL       => BASE_URL . 'artist/%s';
use constant BIOGRAPHY_URL    => BASE_URL . 'artist/%s/biographyAjax';
use constant RELATED_URL      => BASE_URL . 'artist/%s/relatedArtistsAjax';
use constant ALBUMREVIEW_URL  => BASE_URL . 'album/%s/reviewAjax';
use constant ALBUMDETAILS_URL => BASE_URL . 'album/%s';
use constant ALBUMCREDITS_URL => BASE_URL . ALBUMREVIEW_URL . '/creditsAjax';

my $log = logger('plugin.musicartistinfo');

sub getBiography {
	my ( $class, $client, $cb, $args ) = @_;

	my $getBiographyCB = sub {
		my $args = shift;
		my $url = _getBioUrl($args) || return _nothingFound($client, $cb);
		my $referer = $args->{url};

		_get( $client, $cb, {
			url     => $url,
			parseCB => sub {
				my $tree   = shift;
				my $result = {};

				main::DEBUGLOG && $log->is_debug && $tree->dump;

				if ( my $bio = $tree->look_down('_tag', 'div', 'id', 'biography') ) {
					main::DEBUGLOG && $log->is_debug && $log->debug('Found biography - parsing');

					$bio = _cleanupLinksAndImages($bio);

					$result->{bio} = _decodeHTML($bio->as_HTML);
					$result->{bio} =~ s/\bh3\b/h4/ig;
					$result->{bio} =~ s/"headline"//g;
					$result->{bioText} = Encode::decode( 'utf8', join('\n\n', map {
						$_->as_trimmed_text;
					} $bio->content_list) );

					$result->{bio} || $log->warn('Failed to find biography for ' . $url);
				}

				return $result;
			}
		}, ['referer', $referer] );
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
		my $url = _getArtistUrl(shift) || return _nothingFound($client, $cb);

		_get( $client, $cb, {
			url     => $url,
			parseCB => sub {
				my $tree = shift;

				my $result = [];

				if ( my $imageContainer = $tree->look_down('_tag', 'aside') ) {
					my $images = eval {
						my ($script) = map { /(\[.*\])/sg; $1; } grep { $_ } $imageContainer->look_down('_tag', 'script')->content_list;
						from_json($script);
					};

					if ( $@ ) {
						return { error => $@ };
					}
					elsif ( $images && ref $images ) {
						$result = [ map {
							{
								author => $_->{author} || $_->{copyrightOwner} || 'AllMusic.com',
								url    => _makeLinkAbsolute($_->{zoomURL} || $_->{url}),
								height => $_->{zoomURL} ? undef : $_->{height},
								width  => $_->{zoomURL} ? undef : $_->{width},
							}
						} @$images ];
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
		my $url = _getArtistUrl(shift) || return _nothingFound($client, $cb);

		_get( $client, $cb, {
			url     => $url,
			parseCB => sub {
				my $tree   = shift;
				my $result = [];

				my $details = $tree->look_down('_tag', 'div', 'id', 'basicInfoMeta');

				foreach ( 'activeDates', 'birth', 'genre', 'styles', 'group-members', 'aliases', 'member-of' ) {
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
									HTML::Entities::decode(Encode::decode('utf8', $_->as_trimmed_text)) => $_->attr('href')
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
		my $url = _getSomeUrl(shift, '/relatedArtistsAjax', RELATED_URL) || return _nothingFound($client, $cb);

		_get( $client, $cb, {
			url     => $url,
			parseCB => sub {
				my $tree   = shift;
				my $result = [];

				foreach ( 'similars', 'influencers', 'followers', 'associatedwith', 'collaboratorwith' ) {
					my $related = $tree->look_down('_tag', 'div', 'class', "related $_ clearfix") || next;
					my $title = $related->look_down('_tag', 'h2') || next;

					push @$result, {
						$title->as_trimmed_text => [ map {
							_parseArtistInfo($_);
						} $related->look_down("_tag", "a") ]
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

			my $results = $tree->look_down("_tag" => "div", "id" => "resultsContainer");

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
		my $args = shift;
		my $url = _getAlbumReviewUrl($args) || return _nothingFound($client, $cb);
		my $referer = $args->{url};

		_get( $client, $cb, {
			url     => $url,
			parseCB => sub {
				my $tree   = shift;
				my $result = {};

				main::DEBUGLOG && $log->is_debug && $tree->dump;

				if ( my $review = $tree->look_down('_tag', 'div', 'id', 'review') ) {
					main::DEBUGLOG && $log->is_debug && $log->debug('Found reviewBody - parsing');

					$review = _cleanupLinksAndImages($review);

					$result->{review} = _decodeHTML($review->as_HTML);
					$result->{reviewText} = Encode::decode( 'utf8', join('\n\n', map {
						$_->as_trimmed_text;
					} $review->content_list) );
				}

				return $result;
			}
		}, ['referer', $referer] );
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
		my $url = _getAlbumDetailsUrl(shift) || return _nothingFound($client, $cb);

		_get( $client, $cb, {
			url     => $url,
			parseCB => sub {
				my $tree   = shift;
				my $result = [];

				if ( my $details = $tree->look_down('_tag', 'div', 'id', 'basicInfoMeta') ) {
					foreach ( 'release-date', 'recording-date', 'duration', 'genre', 'styles', 'recording-location' ) {
						if ( my $item = $details->look_down('_tag', 'div', 'class', $_) ) {
							my $title = $item->look_down('_tag', 'h4');
							my $value = $item->look_down('_tag', 'span');
							my $values = $item->look_down('_tag', 'div', 'class', undef);

							next unless $title && ($value || $values);
							$title = $title->as_trimmed_text;

							if ( $values && /genre|styles/ ) {
								# XXX - link to genre/artist pages?
								my @values;
								foreach ( $values->look_down('_tag', 'a') ) {
									push @values, $_->as_trimmed_text;
								}

								$value = \@values if scalar @values;
							}
							elsif ( $values && /location/ ) {
								my @values;
								foreach ( $item->look_down('_tag', 'div', 'class', undef) ) {
									push @values, $_->as_trimmed_text;
								}
								$value = join(' & ', @values) if scalar @values;
							}
							elsif ($values) {
								$value = $values->look_down('_tag', 'div', 'class', undef)->as_trimmed_text;
							}
							elsif ($value) {
								$value = $value->as_trimmed_text;
							}

							push @$result, {
								$title => $value,
							} if $title && $value;
						}
					}
				}

=pod
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
=cut

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
		my $url = _getAlbumDetailsUrl(shift) || return _nothingFound($client, $cb);

		_get( $client, $cb, {
			url     => $url,
			parseCB => sub {
				my $tree   = shift;
				my $result = {};

				#main::DEBUGLOG && $log->is_debug && $tree->dump;

				if ( my $cover = $tree->look_down('_tag', 'aside') ) {
					#main::DEBUGLOG && $log->is_debug && $cover->dump;

					my $images = eval {
						my ($script) = map { /(\[.*\])/sg; $1; } grep { $_ } $cover->look_down('_tag', 'script')->content_list;
						from_json($script);
					};

					if ( $@ ) {
						$result->{error} = $@;
					}
					elsif ( $images && ref $images ) {
						$result->{images} = [ map {
							{
								author => $_->{author} || $_->{copyrightOwner} || 'AllMusic.com',
								url    => _makeLinkAbsolute($_->{zoomURL} || $_->{url}),
								height => $_->{zoomURL} ? undef : $_->{height},
								width  => $_->{zoomURL} ? undef : $_->{width},
							}
						} @$images ];
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
		my $url = _getSomeUrl(shift, '/creditsAjax', ALBUMCREDITS_URL) || return _nothingFound($client, $cb);
		my $referer = $url;
		$referer =~ s|/creditsAjax||;

		_get( $client, $cb, {
			url     => $url,
			parseCB => sub {
				my $tree   = shift;
				my $result = [];

				if ( my $credits = $tree->look_down('_tag', 'table', 'class', 'creditsTable') ) {
					foreach ($credits->look_down('_tag', 'tr')) {
						my $artist = $_->look_down('_tag', 'td', 'class', 'singleCredit') || next;

						my $artistData = _parseArtistInfo($artist->look_down('_tag', 'span', 'class', 'artist'));

						if ( my $credit = $artist->look_down('_tag', 'span', 'class', 'artistCredits') ) {
							$artistData->{credit} = $credit->as_trimmed_text;
						}

						push @$result, $artistData if $artistData->{name};
					}
				}

				return {
					items => [ sort { $a->{name} cmp $b->{name} } @$result ]
				};
			}
		}, ['referer', $referer] );
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

	if (!$args->{artist} || !$args->{album}) {
		$cb->();
		return;
	}

	$class->searchAlbums($client, sub {
		my $items = shift;

		if (!$items || ref $items ne 'ARRAY') {
			$cb->();
			return;
		}

		my $albumInfo;

		foreach (@$items) {
			my $candidate = {
				artist => $_->{artist}->{name},
				album  => $_->{name}
			};

			if (Plugins::MusicArtistInfo::Common->matchAlbum($args, $candidate, 'strict')) {
				$albumInfo = $_;
				last;
			}

			if ( !$albumInfo && Plugins::MusicArtistInfo::Common->matchAlbum($args, $candidate)) {
				$albumInfo = $_;
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

			foreach ( $tree->look_down("_tag" => "div", "class" => "album") ) {
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

sub _cleanupLinksAndImages {
	my $tree = shift;

	# clean up links and images
	foreach ( $tree->look_down('_tag', 'a') ) {
		# make external links absolute
		$_->attr('href', _makeLinkAbsolute($_->attr('href')));
		# open links in new window
		$_->attr('target', 'allmusic');
	}

	foreach ( $tree->look_down('_tag', 'img', 'loading', 'lazy') ) {
		$_->attr('onerror', "this.style.display='none'");
		$_->attr('style', 'display:block;margin:"10px 0;');
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
		$artistInfo->{url} = _makeLinkAbsolute($url->attr('href'));

		my $id = _getIdFromUrl($artistInfo->{url});
		$artistInfo->{id} = $id if $id;
	}

	if ( my $decades = $_->look_down('_tag', 'div', 'class', 'decades') ) {
		$artistInfo->{decades} = $decades->as_trimmed_text;
	}

	return $artistInfo;
}

sub _getArtistUrl { _getSomeUrl(shift, '', ARTIST_URL) }

sub _getBioUrl { _getSomeUrl(shift, '/biographyAjax', BIOGRAPHY_URL) }

sub _getAlbumReviewUrl { _getSomeUrl(shift, '/reviewAjax', ALBUMREVIEW_URL) }

sub _getAlbumDetailsUrl { _getSomeUrl(shift, '', ALBUMREVIEW_URL) }

sub _getSomeUrl {
	my ($data, $suffix, $template) = @_;
	return unless $data->{url} || $data->{id};
	return $data->{url}
		? ($data->{url} . ($suffix || ''))
		: sprintf($template, $data->{id});
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

sub _nothingFound {
	my ($client, $cb) = @_;
	$cb->({ error => cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND') })
}

sub _get {
	my ( $client, $cb, $args, $headers ) = @_;

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
	)->get($url, $headers ? @$headers : undef);
}

1;