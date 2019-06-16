package Plugins::MusicArtistInfo::ArtistInfo;

use strict;

use Slim::Menu::ArtistInfo;
use Slim::Menu::AlbumInfo;
use Slim::Menu::TrackInfo;
use Slim::Menu::GlobalSearch;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Log;

use Plugins::MusicArtistInfo::AllMusic;
use Plugins::MusicArtistInfo::Discogs;
use Plugins::MusicArtistInfo::LFM;

use constant CLICOMMAND => 'musicartistinfo';
use constant CAN_IMAGEPROXY => (Slim::Utils::Versions->compareVersions($::VERSION, '7.8.0') >= 0);

my $log   = logger('plugin.musicartistinfo');
my $prefs;

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

	if (CAN_IMAGEPROXY) {
		require Slim::Web::HTTP;
		require Slim::Web::ImageProxy;
		require Plugins::MusicArtistInfo::LocalArtwork;

		Slim::Web::ImageProxy->registerHandler(
			match => qr/mai\/artist\/.+/,
			func  => \&_artworkUrl,
		);

		# dirty re-direct of the Artists menu - delay, as some items might not have registered yet
		require Slim::Utils::Timers;
		Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 2, \&_hijackArtistsMenu);
		Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 15, \&_hijackArtistsMenu);

		$prefs = Slim::Utils::Prefs::preferences('plugin.musicartistinfo');
		$prefs->setChange(\&_hijackArtistsMenu, 'browseArtistPictures');
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

	$args->{artist_id} ||= $params->{artist_id};

	main::DEBUGLOG && $log->debug("Getting artist menu for " . $args->{artist});

	my $pt = [$args];

	my $items = [ {
		name => cstring($client, 'PLUGIN_MUSICARTISTINFO_ARTISTDETAILS'),
		type => 'link',
		url  => \&getArtistInfo,
		passthrough => $pt,
	},{
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

	if ($client) {
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

	# prefer AllMusic.com if language is EN - it's richer than Last.fm
	if ($args->{lang} eq 'en') {
		Plugins::MusicArtistInfo::AllMusic->getBiography($client, sub {
			$cb->(_getBioItems(shift, $client, $params));
		}, $args);
	}
	else {
		Plugins::MusicArtistInfo::LFM->getBiography($client, sub {
			my $bio = shift;

			if ($bio->{error} || !$bio->{bio}) {
				# in case of error or lack of Bio, try to fall back to English
				delete $args->{lang};

				Plugins::MusicArtistInfo::LFM->getBiography($client, sub {
					$bio = shift;

					if ($bio->{error} || !$bio->{bio}) {
						# fall back to AllMusic
						Plugins::MusicArtistInfo::AllMusic->getBiography($client, sub {
							$cb->(_getBioItems(shift, $client, $params));
						}, $args);
					}
					else {
						$cb->(_getBioItems($bio, $client, $params));
					}
				}, $args);
			}
			else {
				$cb->(_getBioItems($bio, $client, $params));
			}
		}, $args);
	}
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

			if ( !$items || !scalar @$items ) {
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

	_getArtistPhotos($client, $artist, $artist_id, sub {
		my $photos = shift;

		my $i = 0;
		foreach (@$photos) {
			$request->addResultLoop('item_loop', $i, 'url', $_->{url} || '');
			$request->addResultLoop('item_loop', $i, 'credits', $_->{credits}) if $_->{credits};
			$request->addResultLoop('item_loop', $i, 'artist_id', $artist_id) if $artist_id;
			$request->addResultLoop('item_loop', $i, 'width', $_->{width}) if $_->{width};
			$request->addResultLoop('item_loop', $i, 'height', $_->{height}) if $_->{height};
			$i++;
		}

		$request->addResult('count', $i);
		$request->addResult('offset', 0);
		$request->setStatusDone();
	});

	$request->setStatusProcessing();
}

sub _getArtistPhotos {
	my ($client, $artist, $artist_id, $cb, $services) = @_;

	$services ||= [ 'local', 'allmusic', 'discogs', 'lfm'	];

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

	Plugins::MusicArtistInfo::AllMusic->getArtistPhotos($client, sub {
		$results->{allmusic} = shift;
		$gotArtistPhotosCb->($results);
	}, $args ) if $services{allmusic};

	Plugins::MusicArtistInfo::LFM->getArtistPhotos($client, sub {
		$results->{lfm} = shift || { photos => [] };
		$gotArtistPhotosCb->($results);
	}, $args ) if $services{lfm};

	Plugins::MusicArtistInfo::Discogs->getArtistPhotos($client, sub {
		$results->{discogs} = shift || { photos => [] };
		$gotArtistPhotosCb->($results);
	}, $args ) if $services{discogs};

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

	$gotArtistPhotosCb->($results);
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

sub getArtistInfo {
	my ($client, $cb, $params, $args) = @_;

	Plugins::MusicArtistInfo::AllMusic->getArtistDetails($client,
		sub {
			my $details = shift;
			my $items = [];

			if ($details->{error}) {
				$items = [{
					name => $details->{error},
					type => 'text'
				}]
			}
			elsif ( $details->{items} ) {
				my $colon = cstring($client, 'COLON');

				$items = [ map {
					my ($k, $v) = each %{$_};

					ref $v eq 'ARRAY' ? {
						name  => $k,
						type  => 'outline',
						items => [ map {
							if (ref $_ eq 'HASH') {
								my ($k, $v) = each %$_;
								{
									name => $k,
									type => 'link',
									url  => \&getArtistMenu,
									passthrough => [{
										url => $v,
										name => $k
									}]
								}
							}
							else {
								my $item = {
									name => $_,
									type => 'text'
								};

								if ( $k =~ /genre|style/i && (my ($genre) = Slim::Schema->rs('Genre')->search( namesearch => Slim::Utils::Text::ignoreCaseArticles($_, 1, 1) )) ) {
									$item->{type} = 'link';
									$item->{url}  = \&Slim::Menu::BrowseLibrary::_artists;
									$item->{passthrough} = [{
										searchTags => ["genre_id:" . $genre->id]
									}];
								}
								elsif ( $k =~ /also known as/i ) {
									$item->{type} = 'link';
									$item->{url}  = \&_getSearchItem;
									$item->{passthrough} = [{
										search => $_
									}];
								}

								$item;
							}
						} @$v ],
					}:{
						name => "$k$colon $v",
						type => 'text'
					}
				} @{$details->{items}} ];

				main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($items));
			}

			$cb->($items);
		},
		$args,
	);
}

sub getRelatedArtists {
	my ($client, $cb, $params, $args) = @_;

	Plugins::MusicArtistInfo::AllMusic->getRelatedArtists($client,
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
					my ($k, $v) = each %{$_};

					{
						name  => $k,
						type  => 'outline',
						items => [ map {
							{
								name => $_->{name},
								type => 'link',
								url  => \&getArtistMenu,
								passthrough => [{
									url => $_->{url},
									id  => $_->{id},
									name => $_->{name}
								}]
							 }
						} @$v ],
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
		$url = Slim::Player::Playlist::song($client);
		$url = $url->url if $url;
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

	if (defined($artistId) && $artistId =~ /^\d+$/) {
		my $artistObj = Slim::Schema->resultset("Contributor")->find($artistId);

		return unless $artistObj;

		my $artist = $artistObj->name;

		main::DEBUGLOG && $artist && $log->debug("Got artist name from artist ID: '$artist'");

		return $artist;
	}
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

sub _artworkUrl { if (CAN_IMAGEPROXY) {
	my ($url, $spec, $cb) = @_;

	my ($artist_id) = $url =~ m|mai/artist/(.+)|i;

	main::INFOLOG && $log->info("Artist ID is '$artist_id'");

	return Slim::Utils::Misc::fileURLFromPath(
		Plugins::MusicArtistInfo::LocalArtwork->defaultArtistPhoto()
	) unless $artist_id;

	my $artist = _getArtistFromArtistId($artist_id) || $artist_id;

	# try local artwork first
	if ( my $local = Plugins::MusicArtistInfo::LocalArtwork->getArtistPhoto({
		artist    => $artist,
		artist_id => $artist_id,
		rawUrl    => 1,
	}) ) {
		main::INFOLOG && $log->info("Found local artwork: $local");
		return Slim::Utils::Misc::fileURLFromPath($local);
	}

	_getArtistPhotos(undef, $artist, ($artist_id && $artist_id ne $artist) ? $artist_id : undef, sub {
		my $photos = shift;

		if (!$photos || !ref $photos || !scalar @$photos) {
			$log->warn(string('PLUGIN_MUSICARTISTINFO_NOT_FOUND'));
			$photos = [];
		}

		my $photo = $photos->[0];

		my $url = $photo->{url} || Slim::Utils::Misc::fileURLFromPath(
			Plugins::MusicArtistInfo::LocalArtwork->defaultArtistPhoto()
		);

		main::INFOLOG && $log->is_info && $log->info("Got artwork for '$artist': $url");

		$cb->($url);
	# we don't use discogs here, as we easily get rate limited
	}, [ 'allmusic', 'lfm' ]);

	return;
} }

sub _getSearchItem {
	my ($client, $cb, $params, $args) = @_;

	$args->{search} ||= $args->{artist} || $args->{name};
	my $searchMenu = Slim::Menu::GlobalSearch->menu( $client, $args ) || {};
	$cb->($searchMenu->{items} || []);
}

# this is an ugly hack to manipulate the main artist menu to inject artist artwork
my $retry = 0.5;
sub _hijackArtistsMenu { if (CAN_IMAGEPROXY) {
	main::DEBUGLOG && $log->is_debug && $prefs->get('browseArtistPictures') && $log->debug('Trying to redirect Artists menu...');

	foreach my $node ( @{ Slim::Menu::BrowseLibrary->_getNodeList() } ) {
		next unless $node->{id} =~ /^myMusicArtists/;

		if ( $prefs->get('browseArtistPictures') && !$node->{mainCB} ) {
			main::DEBUGLOG && $log->debug('BrowseLibrary menu is ready - hijack the Artists menu: ' . $node->{id});

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
		Slim::Web::XMLBrowser::wipeCaches() if Slim::Utils::Versions->compareVersions($::VERSION, '7.9.0') >= 0;
	}
} }

1;