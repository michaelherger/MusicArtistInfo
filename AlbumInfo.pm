package Plugins::MusicArtistInfo::AlbumInfo;

use strict;

use Slim::Menu::AlbumInfo;
use Slim::Menu::TrackInfo;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Log;

use Plugins::MusicArtistInfo::ArtistInfo;
use Plugins::MusicArtistInfo::Common qw(CLICOMMAND CAN_IMAGEPROXY);
use Plugins::MusicArtistInfo::Discogs;
use Plugins::MusicArtistInfo::LFM;
use Plugins::MusicArtistInfo::MusicBrainz;
use Plugins::MusicArtistInfo::Wikipedia;

*_cleanupAlbumName = \&Plugins::MusicArtistInfo::Common::cleanupAlbumName;

my $log = logger('plugin.musicartistinfo');

sub init {
#                                                                     |requires Client
#                                                                     |  |is a Query
#                                                                     |  |  |has Tags
#                                                                     |  |  |  |Function to call
#                                                                     C  Q  T  F
	Slim::Control::Request::addDispatch([CLICOMMAND, 'albumreview'], [0, 1, 1, \&getAlbumReviewCLI]);
	Slim::Control::Request::addDispatch([CLICOMMAND, 'albumcovers'], [0, 1, 1, \&getAlbumCoversCLI]);

	Slim::Menu::AlbumInfo->registerInfoProvider( moremusicinfo => (
		func => \&_objInfoHandler,
		after => 'moreartistinfo',
	) );

	Slim::Menu::TrackInfo->registerInfoProvider( moremusicinfo => (
		func => \&_objInfoHandler,
		after => 'moreartistinfo',
	) );
}

sub getAlbumMenu {
	my ($client, $cb, $params, $args) = @_;

	$params ||= {};
	$args   ||= {};

	my $args2 = $params->{'album'}
			|| _getAlbumFromAlbumId($params->{album_id})
			|| _getAlbumFromSongURL($client) unless $args->{url} || $args->{album_id};

	$args->{album}  ||= $args2->{album};
	$args->{artist} ||= $args2->{artist};
	$args->{album}  = _cleanupAlbumName($args->{album});
	$args->{album_id} = $args2->{album_id};
	$args->{mbid}   ||= $args2->{mbid} if $args2->{mbid};

	main::DEBUGLOG && $log->debug("Getting album menu for " . $args->{album} . ' by ' . $args->{artist});

	my $pt = [$args];

	my $items = [];

	if ( !$params->{isButton} ) {
		unshift @$items, {
			name => cstring($client, 'PLUGIN_MUSICARTISTINFO_ALBUMREVIEW'),
			type => 'link',
			url  => \&getAlbumReview,
			passthrough => $pt,
		};

		push @$items, {
			name => cstring($client, 'PLUGIN_MUSICARTISTINFO_ALBUM_COVER'),
			# we don't want slideshow mode on controllers, but web UI only
			type => ($client && $client->controllerUA || '') =~ /squeezeplay/i ? 'link' : 'slideshow',
			url  => \&getAlbumCovers,
			passthrough => $pt,
		};
	}

	if ($cb) {
		$cb->({
			items => $items,
		});
	}
	else {
		return $items;
	}
}

sub getAlbumReview {
	my ($client, $cb, $params, $args) = @_;

	if ( my $review = Plugins::MusicArtistInfo::LocalFile->getAlbumReview($client, $params, $args) ) {
		$cb->($review);
		return;
	}

	$args->{lang} ||= cstring($client, 'PLUGIN_MUSICARTISTINFO_LASTFM_LANGUAGE');

	Plugins::MusicArtistInfo::API->getAlbumReviewId(
		sub {
			my $reviewData = shift;

			my $reviewCb = sub {
				my $review = shift;
				my $items = [];

				$reviewData->{url} ||= $review->{url} if $review->{url};

				if ($review->{error}) {
					if (keys %$reviewData && Plugins::MusicArtistInfo::Plugin->isWebBrowser($client, $params)) {
						$review->{error} = sprintf("<p>%s</p>\n%s", $review->{error}, Plugins::MusicArtistInfo::Common::getExternalLinks($client, $reviewData));
					}

					$items = [{
						name => $review->{error},
						type => 'text'
					}]
				}
				elsif ($review->{review}) {
					my $content = '';
					if ( Plugins::MusicArtistInfo::Plugin->isWebBrowser($client, $params) ) {
						$content = '<h4>' . $review->{author} . '</h4>' if $review->{author};
						$content .= '<div><img src="' . $review->{image} . '" onerror="this.style.display=\'none\'"></div>' if $review->{image};
						$content .= $review->{review};
						$content .= Plugins::MusicArtistInfo::Common::getExternalLinks($client, $reviewData) if keys %$reviewData;
					}
					else {
						$content = $review->{author} . '\n\n' if $review->{author};
						$content .= $review->{reviewText};
					}

					$items = Plugins::MusicArtistInfo::Plugin->textAreaItem($client, $params->{isButton}, $content);
				}

				$cb->($items);
			};

			# TODO - respect fallback language setting?
			if ($reviewData && (my $pageData = $reviewData->{wikidata})) {
				Plugins::MusicArtistInfo::Wikipedia->getPage($client, sub {
					my $review = shift;

					if ($review && $review->{content} && $review->{contentText}) {
						$review->{review} = delete $review->{content};
						$review->{reviewText} = delete $review->{contentText};
						return $reviewCb->($review);
					}

					Plugins::MusicArtistInfo::Wikipedia->getAlbumReview($client, $reviewCb, $args);
				}, {
					title => $pageData->{title},
					id => $pageData->{pageid},
					lang => $pageData->{lang} || $args->{lang},
				});
			}
			else {
				Plugins::MusicArtistInfo::Wikipedia->getAlbumReview($client, $reviewCb, $args);
			}
		},
		$args,
	);
}

sub getAlbumCovers {
	my ($client, $cb, $params, $args) = @_;

	my $getAlbumCoversCb = sub {
		my $request = shift;

		my $items = [];

		my $covers = $request->getResult('item_loop');
		if ($covers && ref $covers eq 'ARRAY') {
			foreach my $cover (@$covers) {
				my $size = $cover->{size} || '';
				my $type = $cover->{type} || '';

				if ($size) {
					$size .= 'px' if $size =~ /\d+$/;
					$size .= ", $type" if $type;
					$size = " ($size)";
				}
				elsif ($type) {
					$size = " ($type)";
				}

				push @$items, {
					type  => 'text',
					name  => $cover->{credits} . $size,
					image => $cover->{url},
					jive  => {
						showBigArtwork => 1,
						actions => {
							do => {
								cmd => [ 'artwork', $cover->{url} ]
							},
						},
					}
				};
			}
		}

		if ( !scalar @$items ) {
			$items = [{
				name => $covers->{lfm}->{error} || $covers->{discogs}->{error}  || cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND'),
				type => 'text'
			}];
		}

		$cb->($items);
	};

	my $request = Slim::Control::Request::executeRequest( $client, [
		'musicartistinfo', 'albumcovers', 'artist:' . $args->{artist}, 'album:' . $args->{album}
	] );

	if ( $request->isStatusProcessing ) {
		$request->callbackFunction($getAlbumCoversCb);
	} else {
		$getAlbumCoversCb->($request);
	}
}

sub getAlbumCoversCLI {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([[CLICOMMAND], ['albumcovers']])) {
		$request->setStatusBadDispatch();
		return;
	}

	$request->setStatusProcessing();

	my $client = $request->client();

	my $args;
	my $artist = $request->getParam('artist');
	my $album  = $request->getParam('album');

	if (my $mbid   = $request->getParam('mbid')) {
		$args = {
			mbid => $mbid
		};
	}
	elsif ($artist && $album) {
		$args = {
			album  => _cleanupAlbumName($album),
			artist => $artist
		};
	}
	else {
		$args = _getAlbumFromAlbumId($request->getParam('album_id'));
	}

	if ( !$args || (!($args->{artist} && $args->{album}) && !$args->{mbid}) ) {
		$request->addResult('error', cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND'));
		$request->setStatusDone();
		return;
	}

	my $results = {};

	my $getAlbumCoversCb = sub {
		my $covers = shift;

		# only continue once we have results from all services.
		return unless $covers->{lfm} && $covers->{discogs} && $covers->{musicbrainz};

		my $i = 0;
		if ( $covers->{lfm}->{images} || $covers->{discogs}->{images} || $covers->{musicbrainz}->{images} ) {
			my @covers;
			push @covers, @{$covers->{lfm}->{images}} if ref $covers->{lfm}->{images} eq 'ARRAY';
			push @covers, @{$covers->{discogs}->{images}} if ref $covers->{discogs}->{images} eq 'ARRAY';
			push @covers, @{$covers->{musicbrainz}->{images}} if ref $covers->{musicbrainz}->{images} eq 'ARRAY';

			foreach my $cover (@covers) {
				# sometimes we get width=200x200
				my ($w, $h) = split(/x/i, $cover->{width});
				if ($w && $h) {
					$cover->{size} = "${w}x${h}";
					$cover->{width} = $w;
					$cover->{height} = $h;
				}

				if (!$cover->{size}) {
					my $size = $cover->{width} || '';
					if ( $cover->{height} ) {
						$size .= ($size ? 'x' : '') . $cover->{height};
					}

					$cover->{size} = $size;
				}

				my ($type) = $cover->{url} =~ /\.(gif|png|jpe?g)(?:\?.+|)$/i;
				$type = uc($type || '');

				$request->addResultLoop('item_loop', $i, 'url', $cover->{url} || '');
				$request->addResultLoop('item_loop', $i, 'credits', $cover->{author}) if $cover->{author};
				$request->addResultLoop('item_loop', $i, 'size', $cover->{size}) if $cover->{size};
				$request->addResultLoop('item_loop', $i, 'width', $cover->{width}) if $cover->{width};
				$request->addResultLoop('item_loop', $i, 'height', $cover->{height}) if $cover->{height};
				$request->addResultLoop('item_loop', $i, 'type', $type) if $type;
				$i++;
			}
		}

		$request->addResult('count', $i);
		$request->addResult('offset', 0);
		$request->setStatusDone();
	};

	# there's a rate limiting issue on discogs.com: don't use it without imageproxy, as this seems to work around the limitation...
	if (CAN_IMAGEPROXY) {
		Plugins::MusicArtistInfo::Discogs->getAlbumCovers($client, sub {
			$results->{discogs} = shift || {};
			$getAlbumCoversCb->($results);
		}, $args);
	}
	else {
		$results->{discogs} = {};
	}

	Plugins::MusicArtistInfo::MusicBrainz->getAlbumCovers($client, sub {
		$results->{musicbrainz} = shift || {};
		$getAlbumCoversCb->($results);
	}, $args);

	Plugins::MusicArtistInfo::LFM->getAlbumCovers($client, sub {
		$results->{lfm} = shift || {};
		$getAlbumCoversCb->($results);
	}, $args);
}

sub getAlbumReviewCLI {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([[CLICOMMAND], ['albumreview']])) {
		$request->setStatusBadDispatch();
		return;
	}

	$request->setStatusProcessing();

	my $client = $request->client();

	my $args;
	my $artist = $request->getParam('artist');
	my $album  = $request->getParam('album');
	my $lang   = $request->getParam('lang');
	my $mbid   = $request->getParam('mbid');

	if ($artist && $album) {
		$args = {
			album  => _cleanupAlbumName($album),
			artist => $artist,
			mbid   => $mbid,
		};
	}
	else {
		$args = _getAlbumFromAlbumId($request->getParam('album_id'));
	}

	$args->{lang} = $lang if $lang;

	if ( !($args && $args->{artist} && $args->{album}) ) {
		$request->addResult('error', cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND'));
		$request->setStatusDone();
		return;
	}

	getAlbumReview($client,
		sub {
			my $items = shift || [];

			if ($items && ref $items && ref $items eq 'HASH' && $items->{items}) {
				$items = $items->{items};
			}

			if ( !$items || ref $items ne 'ARRAY' || !scalar @$items || $items->[0]->{name} eq cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND') ) {
				$request->addResult('error', cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND'));
			}
			elsif ( $items->[0]->{error} ) {
				$request->addResult('error', $items->[0]->{error});
			}
			elsif ($items) {
				my $item = shift @$items;
				# CLI clients expect real line breaks, not literal \n
				$item->{name} =~ s/\\n/\n/g;
				$request->addResult('albumreview', $item->{name});
				$request->addResult('album_id', $args->{album_id}) if $args->{album_id};
				$request->addResult('album', $args->{album}) if $args->{album};
				$request->addResult('artist', $args->{artist}) if $args->{artist};
			}

			$request->setStatusDone();
		},{
			isWeb  => $request->getParam('html') || Plugins::MusicArtistInfo::Plugin->isWebBrowser($client),
		}, $args
	);
}

sub _objInfoHandler {
	my ( $client, $url, $obj, $remoteMeta ) = @_;

	my ($album, $artist, $album_id, $mbid);

	if ( $obj && blessed $obj ) {
		if ($obj->isa('Slim::Schema::Track')) {
			$album  = $obj->albumname || $remoteMeta->{album};
			$artist = $obj->artistName || $remoteMeta->{artist};
			$album_id = $obj->albumid;
			$mbid	= $obj->album->musicbrainz_id if $obj->album && $obj->album->can('musicbrainz_id');
		}
		elsif ($obj->isa('Slim::Schema::Album')) {
			$album  = $obj->name || $remoteMeta->{name};
			$artist = $obj->contributor->name || $remoteMeta->{artist};
			$album_id = $obj->id || $remoteMeta->{id};
		}
		else {
			#warn Data::Dump::dump($obj);
		}
	}

	if ( !($album && $artist) && $remoteMeta ) {
		$album  ||= $remoteMeta->{album};
		$artist ||= $remoteMeta->{artist};
	}

	# XXX - should we get here? Sounds wrong: this $album is a hashref?!?
	$album = _getAlbumFromSongURL($client, $url) if !$album && $url;

	return unless $album;

	my $args = {
		album => {
			album  => $album,
			artist => $artist,
			album_id => $album_id,
			mbid	 => $mbid,
		}
	};

	my $items = getAlbumMenu($client, undef, $args);

	return {
		name => cstring($client, 'PLUGIN_MUSICARTISTINFO_ALBUMINFO'),
		type => 'outline',
		items => $items,
		passthrough => [ $args ],
	};
}

sub _getAlbumFromAlbumId {
	my $albumId = shift;

	if ($albumId) {
		my $album = Slim::Schema->resultset("Album")->find($albumId);

		if ($album) {
			main::INFOLOG && $log->is_info && $log->info('Got Album/Artist from album ID: ' . $album->title . ' - ' . $album->contributor->name);

			return {
				artist => $album->contributor->name,
				album  => _cleanupAlbumName($album->title),
				album_id => $album->id,
				mbid   => $album->musicbrainz_id,
			};
		}
	}
}

sub _getAlbumFromSongURL {
	my $client = shift;
	my $url = shift;

	return unless $client;

	if ( !defined $url && (my $track = Slim::Player::Playlist::track($client)) ) {
		$url = $track->url;
	}

	if ( $url ) {
		my $track = Slim::Schema->objectForUrl($url);

		my ($artist, $album, $album_id, $mbid);
		$artist = $track->artist->name if (defined $track->artist);
		$album  = $track->album->title if (defined $track->album);
		$mbid   = $track->album->musicbrainz_id if (defined $track->album);
		$album_id = $track->albumid      if (defined $track->album);

		# We didn't get an artist - maybe it is some music service?
		if ( !($album && $artist) && $track->remote() ) {
			my $handler = Slim::Player::ProtocolHandlers->handlerForURL($url);

			if ( $handler && $handler->can('getMetadataFor') ) {
				my $remoteMeta = $handler->getMetadataFor($client, $url);
				$album  ||= $remoteMeta->{album};
				$artist ||= $remoteMeta->{artist};
			}

			main::INFOLOG && $log->info("Got Album/artist from remote track: $album - $artist");
		}
		elsif (main::INFOLOG) {
			main::INFOLOG && $log->info("Got Album/artist current track: $album - $artist");
		}

		if ($album && $artist) {
			return {
				artist => $artist,
				album  => _cleanupAlbumName($album),
				album_id => $album_id,
				mbid   => $mbid,
			};
		}
	}
}

1;