package Plugins::MusicArtistInfo::ArtistInfo;

use strict;
use HTTP::Status qw(RC_MOVED_PERMANENTLY);

use Slim::Menu::ArtistInfo;
use Slim::Menu::AlbumInfo;
use Slim::Menu::TrackInfo;
use Slim::Menu::GlobalSearch;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Log;

use Plugins::MusicArtistInfo::Common qw(CLICOMMAND CAN_IMAGEPROXY CAN_LMS_ARTIST_ARTWORK);
use Plugins::MusicArtistInfo::Discogs;
use Plugins::MusicArtistInfo::LFM;
use Plugins::MusicArtistInfo::API;

my $log   = logger('plugin.musicartistinfo');
my $prefs = Slim::Utils::Prefs::preferences('plugin.musicartistinfo');

sub init {
#                                                                |requires Client
#                                                                |  |is a Query
#                                                                |  |  |has Tags
#                                                                |  |  |  |Function to call
#                                                                C  Q  T  F
	Slim::Control::Request::addDispatch([CLICOMMAND, 'artistphoto'],
	                                                            [0, 1, 1, \&getArtistPhotoCLI]);
	Slim::Control::Request::addDispatch([CLICOMMAND, 'artistphotos'],
	                                                            [0, 1, 1, \&getArtistPhotosCLI]);
	Slim::Control::Request::addDispatch([CLICOMMAND, 'biography'],
	                                                            [0, 1, 1, \&getBiographyCLI]);

	Slim::Menu::GlobalSearch->registerInfoProvider( moreartistinfo => (
		func => \&searchHandler,
	) );

	Slim::Menu::ArtistInfo->registerInfoProvider( moreartistinfo => (
		func => \&artistInfoHandler,
	) );

	Slim::Menu::AlbumInfo->registerInfoProvider( moreartistinfo => (
		func => \&albumInfoHandler,
	) );

	Slim::Menu::TrackInfo->registerInfoProvider( moreartistinfo => (
		func => \&trackInfoHandler,
	) );

	# some clients might still be calling us - redirect to LMS' artist artwork handler
	if (CAN_IMAGEPROXY) {
		require Slim::Web::ImageProxy;
		require Plugins::MusicArtistInfo::LocalArtwork;

		if (CAN_LMS_ARTIST_ARTWORK) {
			Slim::Web::Pages->addRawFunction(
				qr/imageproxy\/mai\/artist\/.+\/image/,
				\&_artworkRedirect,
			);

			# we'll redirect to this guy if the LMS internal image handler fails
			Slim::Web::ImageProxy->registerHandler(
				match => qr/mai\/_artist\/.+/,
				func  => \&_artworkUrl,
			);
		}
		else {
			Slim::Web::ImageProxy->registerHandler(
				match => qr/mai\/artist\/.+/,
				func  => \&_artworkUrl,
			);

			# dirty re-direct of the Artists menu - delay, as some items might not have registered yet
			require Slim::Utils::Timers;
			Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 2, \&_hijackArtistsMenu);
			Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 15, \&_hijackArtistsMenu);

			$prefs->setChange(\&_hijackArtistsMenu, 'browseArtistPictures');
		}
	}
}

sub getArtistMenu {
	my ($client, $cb, $params, $args) = @_;

	$params ||= {};
	$args   ||= {};

	$args->{artist} = $params->{'artist'} || $params->{'name'} || $args->{'name'};

	$args->{artist} ||= _getArtistFromSongId($params->{'track_id'})
			|| _getArtistFromArtistId($params->{'artist_id'})
			|| _getArtistFromAlbumId($params->{'album_id'})
			|| _getArtistFromSongURL($client);

	# remove stuff in brackets, as this is often confusing additions - might want to make this optional?
	$args->{artist} =~ s/\s*\[.*?\]\s*//g;

	$args->{artist_id} ||= $params->{artist_id};

	main::DEBUGLOG && $log->debug("Getting artist menu for " . $args->{artist});

	my $pt = [$args];

	my $items = [ {
		name => cstring($client, 'PLUGIN_MUSICARTISTINFO_RELATED_ARTISTS'),
		type => 'link',
		url  => \&getRelatedArtists,
		passthrough => $pt,
	},{
		name => cstring($client, 'PLUGIN_MUSICARTISTINFO_DISCOGRAPHY'),
		type => 'link',
		url  => \&getDiscography,
		passthrough => $pt,
	} ];

	# if we have an artist ID, we can browse the library
	if ($client && $args->{artist_id}) {
		push @$items, {
			name => cstring($client, 'BROWSE'),
			type => 'link',
			url  => \&Slim::Menu::BrowseLibrary::_albumsOrReleases,
			passthrough => [{
				searchTags => [ 'artist_id:'. $args->{artist_id} ]
			}],
		};
	}
	# if we don't have an ID, but have a name, we can search
	elsif ($client) {
		push @$items, {
			name => cstring($client, 'BROWSE'),
			type => 'link',
			url  => \&_getSearchItem,
			passthrough => $pt,
		};
	}

	# we don't show pictures, videos and length text content on ip3k
	if (!$params->{isButton}) {
		unshift @$items, {
			name => cstring($client, 'PLUGIN_MUSICARTISTINFO_BIOGRAPHY'),
			type => 'link',
			url  => \&getBiography,
			passthrough => $pt,
		};

		push @$items, {
			name => cstring($client, 'PLUGIN_MUSICARTISTINFO_ARTISTPICTURES'),
			type => ($client && $client->controllerUA || '') =~ /squeezeplay/i ? 'link' : 'slideshow',
			url  => \&getArtistPhotos,
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

sub getBiography {
	my ($client, $cb, $params, $args) = @_;

	if ( my $biography = Plugins::MusicArtistInfo::LocalFile->getBiography($client, $params, $args) ) {
		$cb->($biography);
		return;
	}

	$args->{lang} ||= cstring($client, 'PLUGIN_MUSICARTISTINFO_LASTFM_LANGUAGE');

	my $bioCb = sub {
		my $bio = shift;

		if ($bio->{error} || !$bio->{bio}) {
			# in case of error or lack of Bio, try to fall back to English
			delete $args->{lang};

			Plugins::MusicArtistInfo::LFM->getBiography($client, sub {
				$cb->(_getBioItems($_[0], $client, $params));
			}, $args);
		}
		else {
			$cb->(_getBioItems($bio, $client, $params));
		}
	};

	Plugins::MusicArtistInfo::API->getArtistBioId(
		sub {
			my $bioData = shift;

			# TODO - respect fallback language setting?
			if ($bioData && (my $pageData = $bioData->{wikidata})) {
				Plugins::MusicArtistInfo::Wikipedia->getPage($client, sub {
					my $bio = shift;

					if ($bio && $bio->{content} && $bio->{contentText}) {
						$bio->{bio} = (delete $bio->{content}) . Plugins::MusicArtistInfo::Common::getExternalLinks($client, $bioData);
						$bio->{bioText} = delete $bio->{contentText};
						return $bioCb->($bio);
					}

					Plugins::MusicArtistInfo::LFM->getBiography($client, $bioCb, $args);
				}, {
					title => $pageData->{title},
					id => $pageData->{pageid},
					lang => $pageData->{lang} || $args->{lang},
				});
			}
			else {
				Plugins::MusicArtistInfo::LFM->getBiography($client, $bioCb, $args);
			}
		},
		$args,
	);
}

sub _getBioItems {
	my ($bio, $client, $params) = @_;
	my $items = [];

	if ($bio->{error}) {
		$items = [{
			name => $bio->{error},
			type => 'text'
		}]
	}
	elsif ($bio->{bio}) {
		my $content = '';
		if ( Plugins::MusicArtistInfo::Plugin->isWebBrowser($client, $params) ) {
			$content = '<h4>' . $bio->{author} . '</h4>' if $bio->{author};
			$content .= $bio->{bio};
		}
		else {
			$content = $bio->{author} . '\n\n' if $bio->{author};
			$content .= $bio->{bioText} ? $bio->{bioText} : $bio->{bio};
		}

		$items = Plugins::MusicArtistInfo::Plugin->textAreaItem($client, $params->{isButton}, $content);
	}

	return $items;
}

sub getBiographyCLI {
	my $request = shift;

	my ($artist, $artist_id) = _checkRequest($request, ['biography']);

	return unless $artist;

	my $client = $request->client();

	getBiography($client,
		sub {
			my $items = shift || [];

			my (undef, undef, $portraitId) = _getArtistFromArtistId($artist_id || $artist) if CAN_LMS_ARTIST_ARTWORK;

			if ( !$items || !ref $items || ref $items ne 'ARRAY' || !scalar @$items ) {
				main::INFOLOG && $log->is_info && $log->info("No Biography found: " . Data::Dump::dump($items));
				$request->addResult('error', cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND'));
			}
			elsif ( $items->[0]->{error} ) {
				$request->addResult('error', $items->[0]->{error});
			}
			elsif ($items) {
				my $item = shift @$items;
				# CLI clients expect real line breaks, not literal \n
				$item->{name} =~ s/\\n/\n/g;
				$request->addResult('biography', $item->{name});
				$request->addResult('artist_id', $artist_id) if $artist_id;
				$request->addResult('artist', $artist) if $artist;
			}

			$request->addResult('portraitid', $portraitId) if $portraitId;

			$request->setStatusDone();
		},{
			isWeb  => $request->getParam('html') || Plugins::MusicArtistInfo::Plugin->isWebBrowser($client),
		},{
			artist => $artist,
		}
	);
}

sub _checkRequest {
	my ($request, $methods) = @_;

	# check this is the correct query.
	if ($request->isNotQuery([[CLICOMMAND], $methods])) {
		$request->setStatusBadDispatch();
		return;
	}

	$request->setStatusProcessing();

	my $artist_id = $request->getParam('artist_id');
	my $artist = $request->getParam('artist') || _getArtistFromArtistId($artist_id);

	return ($artist, $artist_id) if $artist;

	$request->addResult('error', cstring($request->client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND'));
	$request->setStatusDone();
	return;
}

sub getArtistPhotos {
	my ($client, $cb, $params, $args) = @_;

	_getArtistPhotos($client, $args->{artist}, undef, sub {
		my $photos = shift;

		my $items = [];

		if ($photos && ref $photos eq 'ARRAY') {
			$items = [ map {
				my $credit = cstring($client, 'BY') . ' ';
				{
					type  => 'text',
					name  => $_->{credits} ? ($credit . $_->{credits}) : '',
					image => $_->{url},
					jive  => {
						showBigArtwork => 1,
						actions => {
							do => {
								cmd => [ 'artwork', $_->{url} ]
							},
						},
					}
				}
			} @$photos ];
		}

		if ( !scalar @$items ) {
			$items = [{
				name => cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND'),
				type => 'text'
			}];
		}

		$cb->($items);
	});
}

sub getArtistPhotosCLI {
	my $request = shift;

	my ($artist, $artist_id) = _checkRequest($request, ['artistphotos']);

	return unless $artist;

	my $client = $request->client();

	$request->setStatusProcessing();

	_getArtistPhotos($client, $artist, $artist_id, sub {
		my $photos = shift;

		my $i = 0;
		foreach (@$photos) {
			$request->addResultLoop('item_loop', $i, 'url', $_->{url} || '');
			$request->addResultLoop('item_loop', $i, 'credits', $_->{credits}) if $_->{credits};
			$request->addResultLoop('item_loop', $i, 'artist_id', $artist_id) if $artist_id;
			$request->addResultLoop('item_loop', $i, 'width', $_->{width}) if $_->{width};
			$request->addResultLoop('item_loop', $i, 'height', $_->{height}) if $_->{height};
			$request->addResultLoop('item_loop', $i, 'size', $_->{width} . 'x' . $_->{height}) if $_->{width} && $_->{height};
			$i++;
		}

		$request->addResult('count', $i);
		$request->addResult('offset', 0);
		$request->setStatusDone();
	});
}

sub _getArtistPhotos {
	my ($client, $artist, $artist_id, $cb, $services) = @_;

	$services ||= [ 'local', 'discogs', 'lfm'	];

	my $results = {};

	my $args = {
		artist => $artist,
		artist_id => $artist_id
	};

	my $gotArtistPhotosCb = sub {
		my $photos = shift;

		# only continue once we have results from all services.
		return if scalar grep { !$photos->{$_} } @$services;

		my @photos;
		foreach (@$services) {
			if (ref $photos->{$_}->{photos} && ref $photos->{$_}->{photos} eq 'ARRAY') {
				push @photos, @{$photos->{$_}->{photos}};
			}
		}

		$cb->( [ map {
			my $photo = {
				url => $_->{url}
			};

			$photo->{credits}   = $_->{author} if $_->{author};
			$photo->{artist_id} = $artist_id if $artist_id;
			$photo->{width}     = $_->{width} if $_->{width};
			$photo->{height}    = $_->{height} if $_->{height};

			$photo;
		} grep { $_->{url} } @photos ] );
	};

	my %services = map {
		$_ => 1
	} @$services;

	Plugins::MusicArtistInfo::LFM->getArtistPhotos($client, sub {
		$results->{lfm} = shift || { photos => [] };
		$gotArtistPhotosCb->($results);
	}, $args ) if delete $services{lfm};

	Plugins::MusicArtistInfo::Discogs->getArtistPhotos($client, sub {
		$results->{discogs} = shift || { photos => [] };
		$gotArtistPhotosCb->($results);
	}, $args ) if delete $services{discogs};

	if ($services{'local'}) {
		if (CAN_IMAGEPROXY) {
			my $local = Plugins::MusicArtistInfo::LocalArtwork->getArtistPhoto({
				artist    => $args->{artist},
				artist_id => $args->{artist_id},
			});

			$results->{'local'} = {
				photos => $local ? [{
					url => $local,
					author => cstring($client, 'SETUP_AUDIODIR'),
				}] : [],
			};
		}
		else {
			$results->{'local'}->{photos} = [];
		}
	}

	# make sure we call the callback for all defined services
	foreach (keys %services) {
		$results->{$_} ||= { photos => [] };
		$gotArtistPhotosCb->($results);
	}
}

sub getArtistPhotoCLI {
	my $request = shift;

	my ($artist, $artist_id) = _checkRequest($request, ['artistphoto']);

	return unless $artist;

	# try local artwork first
	if ( CAN_IMAGEPROXY && (Plugins::MusicArtistInfo::LocalArtwork->getArtistPhoto({
		artist    => $artist,
		artist_id => $artist_id,
		rawUrl    => 1,
	})) ) {
		$request->addResult('url', 'imageproxy/mai/artist/' . URI::Escape::uri_escape_utf8($artist_id || $artist) . '/image.png');
		$request->addResult('artist_id', $artist_id) if $artist_id;
		$request->setStatusDone();
		return;
	}

	my $client = $request->client();

	_getArtistPhotos($client, $artist, $artist_id, sub {
		my $photos = shift;

		if (!$photos || !ref $photos || !scalar @$photos) {
			$log->warn(cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND'));
			$request->addResult('error', cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND'))
		}
		else {
			my $photo = $photos->[0];

			$request->addResult('url', $photo->{url} || '');
			$request->addResult('credits', $photo->{credits}) if $photo->{credits};
			$request->addResult('artist_id', $artist_id) if $artist_id;
			$request->addResult('width', $photo->{width}) if $photo->{width};
			$request->addResult('height', $photo->{height}) if $photo->{height};
		}

		$request->setStatusDone();
	});

	$request->setStatusProcessing();
}

sub getRelatedArtists {
	my ($client, $cb, $params, $args) = @_;

	Plugins::MusicArtistInfo::LFM->getRelatedArtists($client,
		sub {
			my $relations = shift;
			my $items = [];

			if ($relations->{error}) {
				$items = [{
					name => $relations->{error},
					type => 'text'
				}]
			}
			elsif ( $relations->{items} ) {
				$items = [ map {
					{
						name => $_->{name},
						type => 'link',
						url  => \&getArtistMenu,
						passthrough => [{
							url => $_->{url},
							name => $_->{name}
						}]
					}
				} @{$relations->{items}} ];
			}

			$cb->($items);
		},
		$args,
	);
}

sub getDiscography {
	my ($client, $cb, $params, $args) = @_;

	Plugins::MusicArtistInfo::Discogs->getDiscography($client, sub {
		my $items = shift;

		$items = [ map { {
			name => $_->{title} . ($_->{'year'} ? ' (' . $_->{'year'} . ')' : ''),
			image => $_->{image},
			url => \&Plugins::MusicArtistInfo::AlbumInfo::getAlbumMenu,
			passthrough => [{
				artist => $args->{artist},
				album => $_->{title},
			}]
		} } sort {
			$a->{year} cmp $b->{year}
		} @{$items->{releases}} ];

		$cb->($items);
	}, $args);

=pod
	Plugins::MusicArtistInfo::MusicBrainz->getDiscography($client,
		sub {
			my $releases = shift;

			# we don't really want the full list - collapse albums by name, sort by date
			my %seen;
			my $items = [ map { {
				name => $_->{title} . ($_->{'date'} ? ' (' . $_->{'date'} . ')' : ''),
				image => $_->{cover}
			} } sort {
				substr($a->{date} . '-01-01', 0, 10) cmp substr($b->{date} . '-01-01', 0, 10);
			} @$releases ];

			$cb->($items);
		},
		$args
	);
=cut
}

sub trackInfoHandler {
	my ( $client, $url, $track, $remoteMeta ) = @_;

	if ( !$track->remote && $track->contributors->count > 1 ) {
		my $items = [];
		my %seen;

		foreach my $role (Slim::Schema::Contributor->contributorRoles) {
			my $contributors = $track->contributorsOfType($role);

			while (my $contributor = $contributors->next) {
				next if $seen{$contributor->id};

				my $item = _objInfoHandler( $client, $contributor->name, undef, $contributor->id );
				$item->{name} = $contributor->name . ' (' . cstring($client, $role) . ')' if $item && ref $item;
				push @$items, $item;

				$seen{$contributor->id}++;
			}
		}

		return {
			name => cstring($client, 'PLUGIN_MUSICARTISTINFO_ARTISTINFO'),
			type => 'outline',
			items => $items,
		};
	}
	else {
		return _objInfoHandler( $client, $track->artistName || $remoteMeta->{artist}, $url, $track->remote || $track->artistid );
	}
}

sub artistInfoHandler {
	my ( $client, $url, $artist, $remoteMeta ) = @_;
	return _objInfoHandler( $client, $artist->name || $remoteMeta->{artist}, $url, $artist->id );
}

sub albumInfoHandler {
	my ( $client, $url, $album, $remoteMeta ) = @_;

	if ( $album->contributors->count > 1 ) {
		my $items = [];
		my %seen;

		foreach my $role (Slim::Schema::Contributor->contributorRoles) {
			my @contributors = $album->artistsForRoles($role);

			foreach my $contributor (@contributors) {
				next if $seen{$contributor->id};

				my $item = _objInfoHandler( $client, $contributor->name, undef, $contributor->id );
				$item->{name} = $contributor->name . ' (' . cstring($client, $role) . ')' if $item && ref $item;
				push @$items, $item;

				$seen{$contributor->id}++;
			}
		}

		return {
			name => cstring($client, 'PLUGIN_MUSICARTISTINFO_ARTISTINFO'),
			type => 'outline',
			items => $items,
		};
	}
	else {
		return _objInfoHandler( $client, $album->contributor->name || $remoteMeta->{artist}, $url, $album->contributorid );
	}
}

sub searchHandler {
	my ( $client, $tags ) = @_;
	return _objInfoHandler( $client, $tags->{search} );
}

sub _objInfoHandler {
	my ( $client, $artist, $url, $artist_id ) = @_;

	($artist_id, $artist) = _getArtistFromSongURL($client, $url) if !$artist && $url;

	return unless $artist;

	my $args = {
		artist => $artist,
		artist_id => $artist_id,
	};

	my $items = getArtistMenu($client, undef, $args);

	return {
		name => cstring($client, 'PLUGIN_MUSICARTISTINFO_ARTISTINFO'),
		type => 'outline',
		items => $items,
		passthrough => [ $args ],
	};
}


sub _getArtistFromSongURL {
	my $client = shift;
	my $url    = shift;

	return unless $client;

	if ( !$url ) {
		my $track = Slim::Player::Playlist::track($client);
		$url = $track->url if $track;
	}

	if ( $url ) {
		my $track = Slim::Schema->objectForUrl($url);

		my $artist = $track->artistName;
		my $id     = $track->remote() ? undef : $track->artistid;
		main::DEBUGLOG && $artist && $log->debug("Got artist name from current track: '$artist'");

		# We didn't get an artist - maybe it is some music service?
		if (!$artist && $track->remote()) {
			my $handler = Slim::Player::ProtocolHandlers->handlerForURL($url);
			if ( $handler && $handler->can('getMetadataFor') ) {
				my $remoteMeta = $handler->getMetadataFor($client, $url);
				$artist = $remoteMeta->{artist};
			}
			main::DEBUGLOG && $artist && $log->debug("Got artist name from current remote track: '$artist'");
		}

		return wantarray ? ($artist, $id) : $artist;
	}
}

sub _getArtistFromSongId {
	my $trackId = shift;

	if (defined($trackId) && $trackId =~ /^\d+$/) {
		my $track = Slim::Schema->resultset("Track")->find($trackId);

		return unless $track;

		my $artist = $track->artist->name if $track->artist;

		main::DEBUGLOG && $artist && $log->debug("Got artist name from song ID: '$artist'");

		return $artist;
	}
}

sub _getArtistFromArtistId {
	my $artistId = shift;

	return unless defined($artistId);

	my $artistObj;

	if ($artistId =~ /^\d+$/) {
		$artistObj = Slim::Schema->resultset("Contributor")->find($artistId);
	}

	$artistObj ||= Slim::Schema->rs("Contributor")->search({ 'namesearch' => Slim::Utils::Text::ignoreCaseArticles($artistId) })->first;

	return unless $artistObj;

	my $artist = $artistObj->name;

	main::INFOLOG && $artist && $log->info("Got artist name from artist ID: '$artist'");

	my @responseList;
	if (wantarray) {
		@responseList = ($artist, $artistObj->musicbrainz_id);
		push @responseList, $artistObj->portraitid if CAN_LMS_ARTIST_ARTWORK;
	}

	return wantarray ? @responseList : $artist;
}

sub _getArtistFromAlbumId {
	my $albumId = shift;

	if (defined($albumId) && $albumId =~ /^\d+$/) {
		my $album = Slim::Schema->resultset("Album")->find($albumId);

		return unless $album;

		my $artist = $album->contributor->name;

		main::DEBUGLOG && $artist && $log->debug("Got artist name from album ID: '$artist'");

		return $artist;
	}
}

sub _artworkRedirect { if (CAN_LMS_ARTIST_ARTWORK) {
	my ($httpClient, $response) = @_;

	my $path = $response->request->uri->path;
	my ($artistId, $spec) = $path =~ m|imageproxy/mai/artist/(.+)/image(_.*)?|;

	my (undef, undef, $portraitId) = _getArtistFromArtistId($artistId);

	$response->code(RC_MOVED_PERMANENTLY);

	if ($portraitId) {
		$response->header('Location' => "/contributor/$portraitId/image$spec");
	}
	else {
		$path =~ s|/artist/|/_artist/|;
		$response->header('Location' => $path);
	}

	$response->header('Connection' => 'close');
	return Slim::Web::HTTP::addHTTPResponse( $httpClient, $response, \"" );
} }

sub _artworkUrl {
	my ($url, $spec, $cb) = @_;

	my ($artist_id) = $url =~ m|mai/_?artist/(.+)|i;

	return Slim::Utils::Misc::fileURLFromPath(
		Plugins::MusicArtistInfo::LocalArtwork->defaultArtistPhoto()
	) unless $artist_id;

	my ($artist, $mbid) = _getArtistFromArtistId($artist_id);
	$artist ||= $artist_id;

	main::INFOLOG && $log->info("Artist ID is '$artist_id', name '$artist', musicbrainz ID '$mbid'");

	# try local artwork first
	if ( my $local = Plugins::MusicArtistInfo::LocalArtwork->getArtistPhoto({
		artist    => $artist,
		artist_id => $artist_id,
		rawUrl    => 1,
	}) ) {
		main::INFOLOG && $log->info("Found local artwork: $local");
		return Slim::Utils::Misc::fileURLFromPath($local);
	}

	Plugins::MusicArtistInfo::API->getArtistPhoto(sub {
		my $photo = shift || {};

		if (!$photo->{url}) {
			$log->warn(string('PLUGIN_MUSICARTISTINFO_NOT_FOUND'));
		}

		my $url = $photo->{url} || Slim::Utils::Misc::fileURLFromPath(
			Plugins::MusicArtistInfo::LocalArtwork->defaultArtistPhoto()
		);

		main::INFOLOG && $log->is_info && $log->info("Got artwork for '$artist': $url");

		$cb->($url);
	}, {
		artist => $artist,
		mbid  => $mbid,
	});

	return;
}

sub _getSearchItem {
	my ($client, $cb, $params, $args) = @_;

	$args->{search} ||= $args->{artist} || $args->{name};
	my $searchMenu = Slim::Menu::GlobalSearch->menu( $client, $args ) || {};
	$cb->($searchMenu->{items} || []);
}

# this is an ugly hack to manipulate the main artist menu to inject artist artwork
my $retry = 0.5;
sub _hijackArtistsMenu { if (CAN_IMAGEPROXY && !CAN_LMS_ARTIST_ARTWORK) {
	main::DEBUGLOG && $log->is_debug && $prefs->get('browseArtistPictures') && $log->debug('Trying to redirect Artists menu...');

	foreach my $node ( @{ Slim::Menu::BrowseLibrary->_getNodeList() } ) {
		next unless $node->{id} =~ /^myMusicArtists/;

		if ( $prefs->get('browseArtistPictures') && !$node->{mainCB} ) {
			main::INFOLOG && $log->info('BrowseLibrary menu is ready - hijack the Artists menu: ' . $node->{id});

			Slim::Menu::BrowseLibrary->deregisterNode($node->{id});

			my $cb = $node->{feed};
			$node->{feed} = sub {
				my ($client, $callback, $args, $pt) = @_;
				$cb->($client, sub {
					my $items = shift;

					$items->{items} = [ map {
						if (!$_->{image} && $_->{passthrough} && ref $_->{passthrough} && @{$_->{passthrough}} && $_->{passthrough}->[0]->{remote_library}) {
							$_->{image} ||= 'imageproxy/mai/artist/' . URI::Escape::uri_escape_utf8($_->{name} || 0) . '/image.png';
						}
						else {
							$_->{image} ||= 'imageproxy/mai/artist/' . ($_->{id} || 0) . '/image.png';
						}
						$_;
					} @{$items->{items}} ];

					$callback->($items);
				}, $args, $pt);
			};
			$node->{mainCB} = $cb;
			Slim::Menu::BrowseLibrary->registerNode($node);
		}
		elsif ( !$prefs->get('browseArtistPictures') && $node->{mainCB} ) {
			main::DEBUGLOG && $log->debug('Artist menu was hijacked - let\'s free it!');

			Slim::Menu::BrowseLibrary->deregisterNode($node->{id});

			$node->{feed} = delete $node->{mainCB};

			Slim::Menu::BrowseLibrary->registerNode($node);
		}

		$retry = 0;
	}

	if ($retry) {
		$retry *= 2;
		$retry = $retry > 30 ? 30 : $retry;

		main::DEBUGLOG && $log->debug("Failed the hijacking... will try again in $retry seconds.");
		Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + $retry, \&_hijackArtistsMenu);
	}
	else {
		Slim::Web::XMLBrowser::wipeCaches() if main::WEBUI && Slim::Utils::Versions->compareVersions($::VERSION, '7.9.0') >= 0;
	}
} }

1;