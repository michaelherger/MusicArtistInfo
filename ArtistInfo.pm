package Plugins::MusicArtistInfo::ArtistInfo;

use strict;

use Slim::Menu::ArtistInfo;
use Slim::Menu::AlbumInfo;
use Slim::Menu::TrackInfo;
use Slim::Menu::GlobalSearch;
use Slim::Utils::Cache;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Log;

use Plugins::MusicArtistInfo::AllMusic;
use Plugins::MusicArtistInfo::LFM;
use Plugins::MusicArtistInfo::LocalArtwork;
use Plugins::MusicArtistInfo::TEN;

use constant CLICOMMAND => 'musicartistinfo';
use constant CAN_IMAGEPROXY => (Slim::Utils::Versions->compareVersions($::VERSION, '7.8.0') >= 0);

my $log   = logger('plugin.musicartistinfo');
my $cache = Slim::Utils::ArtworkCache->new();
my $prefs;
my $defaultImg;

sub init {
#                                                                |requires Client
#                                                                |  |is a Query
#                                                                |  |  |has Tags
#                                                                |  |  |  |Function to call
#                                                                C  Q  T  F
	Slim::Control::Request::addDispatch([CLICOMMAND, 'videos'], [1, 1, 1, \&getArtistWeblinksCLI]);
	Slim::Control::Request::addDispatch([CLICOMMAND, 'blogs'],  [1, 1, 1, \&getArtistWeblinksCLI]);
	Slim::Control::Request::addDispatch([CLICOMMAND, 'news'],   [1, 1, 1, \&getArtistWeblinksCLI]);
	Slim::Control::Request::addDispatch([CLICOMMAND, 'urls'],   [1, 1, 1, \&getArtistWeblinksCLI]);
	Slim::Control::Request::addDispatch([CLICOMMAND, 'artistphoto'],
	                                                            [0, 1, 1, \&getArtistPhotoCLI]);

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

		Slim::Web::ImageProxy->registerHandler(
			match => qr/mai\/artist\/.+/,
			func  => \&_artworkUrl,
		);
		
		$defaultImg = Slim::Utils::Misc::fileURLFromPath( 
			Slim::Web::HTTP::getSkinManager->fixHttpPath('', '/html/images/artists.png')
		);
		
		# dirty re-direct of the Artists menu...
		# XXX - make this optional?
		# XXX - should pre-cache artwork if enabled?
		require Slim::Utils::Timers;
		Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 1, \&_hijackArtistsMenu);

		$prefs = Slim::Utils::Prefs::preferences('plugin.musicartistinfo');
		$prefs->setChange(\&_hijackArtistsMenu, 'browseArtistPictures');
	}

	Plugins::MusicArtistInfo::TEN->init($_[1]);
	Plugins::MusicArtistInfo::LFM->init($_[1]);
}

sub getArtistMenu {
	my ($client, $cb, $params, $args) = @_;
	
	$params ||= {};
	$args   ||= {};
	
	$args->{artist} = $params->{'artist'} 
			|| _getArtistFromSongId($params->{'track_id'}) 
			|| _getArtistFromArtistId($params->{'artist_id'}) 
			|| _getArtistFromAlbumId($params->{'album_id'}) 
			|| _getArtistFromSongURL($client) unless $args->{url} || $args->{id};
	
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
	} ];
	
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

		# XMLBrowser for Jive can't handle weblinks - need custom handling there to show videos, blogs etc.
		# don't show blog/news summaries on iPeng, but link instead. And show videos!
		if ($client && $client->controllerUA && $client->controllerUA =~ /iPeng/i)  {
			push @$items, {
				name => cstring($client, 'PLUGIN_MUSICARTISTINFO_ARTISTNEWS'),
				itemActions => {
					items => {
						command  => [ CLICOMMAND, 'news' ],
						fixedParams => $args,
					},
				},
			},{
				name => cstring($client, 'PLUGIN_MUSICARTISTINFO_ARTISTBLOGS'),
				itemActions => {
					items => {
						command  => [ CLICOMMAND, 'blogs' ],
						fixedParams => $args,
					},
				},
			},{
				name => cstring($client, 'PLUGIN_MUSICARTISTINFO_ARTISTVIDEOS'),
				itemActions => {
					items => {
						command  => [ CLICOMMAND, 'videos' ],
						fixedParams => $args,
					},
				},
			},{
				name => cstring($client, 'PLUGIN_MUSICARTISTINFO_URLS'),
				itemActions => {
					items => {
						command  => [ CLICOMMAND, 'urls' ],
						fixedParams => $args,
					},
				},
			};
		}
		
		else {
			push @$items, {
				name => cstring($client, 'PLUGIN_MUSICARTISTINFO_ARTISTNEWS'),
				type => 'link',
				url  => \&getArtistNews,
				passthrough => $pt,
			},{
				name => cstring($client, 'PLUGIN_MUSICARTISTINFO_ARTISTBLOGS'),
				type => 'link',
				url  => \&getArtistBlogs,
				passthrough => $pt,
			};
			
			push @$items, {
				name => cstring($client, 'PLUGIN_MUSICARTISTINFO_ARTISTVIDEOS'),
				type => 'link',
				url  => \&getArtistVideos,
				passthrough => $pt,
			}, {
				name => cstring($client, 'PLUGIN_MUSICARTISTINFO_URLS'),
				type => 'link',
				url  => \&getArtistURLs,
				passthrough => $pt,
			} if !$client || !$client->controllerUA;
		}
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

	Plugins::MusicArtistInfo::AllMusic->getBiography($client,
		sub {
			my $bio = shift;
			my $items = [];
			
			if ($bio->{error}) {
				$items = [{
					name => $bio->{error},
					type => 'text'
				}]
			}
			elsif ($bio->{bio}) {
				my $content = '';
				if ( $params->{isWeb} ) {
					$content = '<h4>' . $bio->{author} . '</h4>' if $bio->{author};
					$content .= $bio->{bio};
				}
				else {
					$content = $bio->{author} . '\n\n' if $bio->{author};
					$content .= $bio->{bioText};
				}
				
				push @$items, {
					name => $content,
					type => 'textarea',
				};
			}
			
			$cb->($items);
		},
		$args,
	);
}

sub getArtistPhotos {
	my ($client, $cb, $params, $args) = @_;

	my $results = {};

	my $getArtistPhotoCb = sub {
		my $photos = shift;

		# only continue once we have results from all services.
		return unless $photos->{ten} && $photos->{lfm} && $photos->{allmusic} && $photos->{'local'};

		my $items = [];

		if ( $photos->{ten}->{photos} || $photos->{lfm}->{photos} || $photos->{allmusic}->{photos} || $photos->{'local'}->{photos} ) {
			my @photos;
			push @photos, @{$photos->{'local'}->{photos}} if ref $photos->{'local'}->{photos} eq 'ARRAY';
			push @photos, @{$photos->{lfm}->{photos}} if ref $photos->{lfm}->{photos} eq 'ARRAY';
			push @photos, @{$photos->{allmusic}->{photos}} if ref $photos->{allmusic}->{photos} eq 'ARRAY';
			push @photos, @{$photos->{ten}->{photos}} if ref $photos->{ten}->{photos} eq 'ARRAY';

			$items = [ map {
				my $credit = cstring($client, 'BY') . ' ';
				{
					type  => 'text',
					name  => $_->{author} ? ($credit . $_->{author}) : '',
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
			} @photos ];
		}

		if ( !scalar @$items ) {
			$items = [{
				name => $photos->{lfm}->{error} || $photos->{allmusic}->{error} || cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND'),
				type => 'text'
			}];
		}
		
		$cb->($items);
	};
	
	Plugins::MusicArtistInfo::AllMusic->getArtistPhotos($client, sub {
		$results->{allmusic} = shift;
		$getArtistPhotoCb->($results);
	}, $args );

	Plugins::MusicArtistInfo::LFM->getArtistPhotos($client, sub {
		$results->{lfm} = shift;
		$getArtistPhotoCb->($results);
	}, $args );

	Plugins::MusicArtistInfo::TEN->getArtistPhotos(sub {
		$results->{ten} = shift;
		$getArtistPhotoCb->($results);
	}, $args );
	
	my $local = Plugins::MusicArtistInfo::LocalArtwork->getArtistPhoto($args);
	
	$results->{'local'} = {
		photos => $local ? [{ 
			url => $local,
			author => cstring($client, 'SETUP_AUDIODIR'),
		}] : [],
	};
	
	$getArtistPhotoCb->($results);
}

sub getArtistPhotoCLI {
	my $request = shift;

	my $handler;
	# check this is the correct query.
	if ( $request->isNotQuery([[CLICOMMAND], ['artistphoto']]) ) {
		$request->setStatusBadDispatch();
		return;
	}
	
	$request->setStatusProcessing();
	
	my $client = $request->client();
	my $artist_id = $request->getParam('artist_id');
	my $artist = $request->getParam('artist') || _getArtistFromArtistId($artist_id);

	if (!$artist) {
		$request->addResult('error', 'No artist found');
		$request->setStatusDone();
		return;
	}
	
	# try local artwork first
	if ( my $img = Plugins::MusicArtistInfo::LocalArtwork->getArtistPhoto({
		artist    => $artist,
		artist_id => $artist_id,
		rawUrl    => 1,
	}) ) {
		$request->addResult('url', Slim::Web::ImageProxy::proxiedImage('mai/artist/' . ($artist_id || $artist), 'force'));
		$request->addResult('artist_id', $artist_id) if $artist_id;
		$request->setStatusDone();
		return;
	}

	Plugins::MusicArtistInfo::LFM->getArtistPhoto($client, sub {
		my $photo = shift || {};

		if ($photo->{error}) {
			$log->warn($photo->{error});
			$request->addResult('error', $photo->{error})
		}
		else {
			$request->addResult('url', $photo->{url});
			$request->addResult('credits', $photo->{author} || ''),
			$request->addResult('artist_id', $artist_id) if $artist_id;
		}

		$request->setStatusDone();
	},{
		artist => $artist,
	} );
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
									}]
								}
							}
							else {
								{
									name => $_,
									type => 'text'
								}
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
									id  => $_->{id}
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

sub getArtistNews {
	my ($client, $cb, $params, $args) = @_;

	Plugins::MusicArtistInfo::TEN->getArtistNews(
		sub {
			_gotWebLinks($cb, $params, shift);
		},
		$args,
	);
}

sub getArtistBlogs {
	my ($client, $cb, $params, $args) = @_;

	Plugins::MusicArtistInfo::TEN->getArtistBlogs(
		sub {
			_gotWebLinks($cb, $params, shift);
		},
		$args,
	);
}

sub getArtistVideos {
	my ($client, $cb, $params, $args) = @_;

	Plugins::MusicArtistInfo::TEN->getArtistVideos(
		sub {
			_gotWebLinks($cb, $params, shift);
		},
		$args,
	);
}

sub getArtistURLs {
	my ($client, $cb, $params, $args) = @_;

	Plugins::MusicArtistInfo::TEN->getArtistURLs(
		sub {
			_gotWebLinks($cb, $params, shift);
		},
		$args,
	);
}

sub _gotWebLinks {
	my ($cb, $params, $result) = @_; 

	my $items = [];
	$result ||= {};

	if ($result->{error}) {
		$items = [{
			name => $result->{error},
			type => 'text'
		}]
	}
	elsif ($result->{items} && $params->{isWeb}) {
		$items = [ map {
			my $title = $_->{name} || $_->{title};
			$title = $_->{date_found} . ' - ' . $title if $_->{date_found};
			$title .= ' (' . $_->{site} . ')' if $_->{site};
			
			{
				name  => $title,
				image => $_->{image_url},
				type  => 'redirect',
				weblink => $_->{url},
			}
		} @{$result->{items}} ];
	}
	elsif ($result->{items}) {
		$items = [ map {
			my $title = $_->{name} || $_->{title};
			$title = $_->{date_found} . ' - ' . $title if $_->{date_found};
			my $item = {
				name  => $title,
			};
			
			$item->{image} = $_->{image_url} if $_->{image_url};
			
			if ($_->{summary}) {
				$_->{summary} =~ s/<\/?span>//g;
				
				$_->{summary} .= '\n\n' . $_->{url} if $_->{url};
				
				$item->{items} = [{
					name => $_->{summary},
					type => 'textarea',
				}] ;
			}
			$item;
		} @{$result->{items}} ];
	}

	$cb->($items);
}

sub getArtistWeblinksCLI {
	my $request = shift;

	my $handler;
	# check this is the correct query.
	if ($request->isNotQuery([[CLICOMMAND], ['videos', 'blogs', 'news', 'urls']]) || !$request->client()) {
		$request->setStatusBadDispatch();
		return;
	}
	elsif ($request->isQuery([[CLICOMMAND], ['news']]) || !$request->client()) {
		$handler = sub { Plugins::MusicArtistInfo::TEN->getArtistNews(@_) };
	}
	elsif ($request->isQuery([[CLICOMMAND], ['blogs']]) || !$request->client()) {
		$handler = sub { Plugins::MusicArtistInfo::TEN->getArtistBlogs(@_) };
	}
	elsif ($request->isQuery([[CLICOMMAND], ['videos']]) || !$request->client()) {
		$handler = sub { Plugins::MusicArtistInfo::TEN->getArtistVideos(@_) };
	}
	elsif ($request->isQuery([[CLICOMMAND], ['urls']]) || !$request->client()) {
		$handler = sub { Plugins::MusicArtistInfo::TEN->getArtistURLs(@_) };
	}
	
	$request->setStatusProcessing();
	
	my $client = $request->client();
	my $artist = $request->getParam('artist');

	$handler->(
		sub {
			my $items = shift || {};

			my $i = 0;
			my $hasImages;

			if ($items->{error}) {
				$request->addResult('window', {
					textArea => $items->{error},
				});
				$i++;
			}
			elsif ($items->{items}) {
				foreach (@{$items->{items}}) {
					my $url = $_->{url};

#					if ($url =~ /youtube/) {
#						my ($id) = $url =~ /v=(\w+)\b/;
#						logError($id);
#						$url = 'http://y2u.be/' . $id;
#						logError($url);
#					}
					
#					logError($url);

					$hasImages ||= $_->{image_url};
					
					$request->addResultLoop('item_loop', $i, 'text', ($_->{title} || $_->{name}) . "\n" . ($_->{site} ? $_->{site} . ' - ' : '') . $_->{date_found} );
					$request->addResultLoop('item_loop', $i, 'icon', $_->{image_url}) if $_->{image_url};
					$request->addResultLoop('item_loop', $i, 'weblink', $url);
					
					$i++;
				}
			}
									
			$request->addResult('window', {
				windowStyle => 'icon_list'
			}) if $hasImages;
			$request->addResult('count', $i);
			$request->addResult('offset', 0);
			$request->setStatusDone();
		},
		{
			artist => $artist
		},
	);
}

sub trackInfoHandler {
	my ( $client, $url, $track, $remoteMeta ) = @_;
	return _objInfoHandler( $client, $track->artistName || $remoteMeta->{artist}, $url );
}

sub artistInfoHandler {
	my ( $client, $url, $artist, $remoteMeta ) = @_;
	return _objInfoHandler( $client, $artist->name || $remoteMeta->{artist}, $url );
}

sub albumInfoHandler {
	my ( $client, $url, $album, $remoteMeta ) = @_;
	return _objInfoHandler( $client, $album->contributor->name || $remoteMeta->{artist}, $url );
}

sub searchHandler {
	my ( $client, $tags ) = @_;
	return _objInfoHandler( $client, $tags->{search} );
}

sub _objInfoHandler {
	my ( $client, $artist, $url ) = @_;

	$artist = _getArtistFromSongURL($client, $url) if !$artist && $url;

	return unless $artist;

	my $args = {
		artist => $artist
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

		my $artist;

		$artist = $track->artist->name if $track->artist;
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

		# We still didn't get an artist - try to extract one from the title.
#		unless ($artist && ($artist ne string('NO_ARTIST'))) {
#			$log->debug("Biography (get artist's name): artist's name is either empty or 'No artist'");
#			$artist = Slim::Music::Info::getCurrentTitle('', $url);
#			$log->debug("Biography (get artist's name): give the track's title a try (for streams): '$artist'");
#
#			$artist =~ /([^\-]+?) -/;
#			if ($1) {
#				$artist = $1;
#				$log->debug("Biography (get artist's name): tried to match 'artist - song': '$artist'");
#			}
#		}
		return $artist;
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
	
	main::DEBUGLOG && $log->debug("Artist ID is '$artist_id'");
	
	return $defaultImg unless $artist_id;

	my $artist = _getArtistFromArtistId($artist_id) || $artist_id;
	
	# try local artwork first
	if ( my $local = Plugins::MusicArtistInfo::LocalArtwork->getArtistPhoto({
		artist    => $artist,
		artist_id => $artist_id,
		rawUrl    => 1,
	}) ) {
		return $local;
	}

	Plugins::MusicArtistInfo::LFM->getArtistPhoto(undef, sub {
		my $photo = shift || {};
		
		my $img = $defaultImg;
		my $sizeMap = {
			252 => 252,
			500 => 500,
		};
		my $defaultSize = '_';

		if (my $url = $photo->{url}) {
			$img = $url;
			# if we've hit one of those huge files, go with a known max of 500px
			$defaultSize = 500 if ($photo->{width} && $photo->{width} > 1500) || ($photo->{height} && $photo->{height} > 1500);
		}
		
		my $size = Slim::Web::ImageProxy->getRightSize($spec, $sizeMap) || $defaultSize;
		$img =~ s/\/_\//\/$size\//;

		$cb->($img);
	},{
		artist => $artist,
	} );

	return;
} }

# this is an ugly hack to manipulate the main artist menu to inject artist artwork
my $retry = 0.5;
sub _hijackArtistsMenu { if (CAN_IMAGEPROXY) {
	main::DEBUGLOG && $log->debug('Trying to redirect Artists menu...');

	if ( my ($node) = grep { $_->{id} eq 'myMusicArtists' } @{ Slim::Menu::BrowseLibrary->_getNodeList() } ) {
		
		if ( $prefs->get('browseArtistPictures') && !$node->{mainCB} ) {
			main::DEBUGLOG && $log->debug('BrowseLibrary menu is ready - hijack the Artists menu!');
	
			Slim::Menu::BrowseLibrary->deregisterNode($node->{id});
	
			my $cb = $node->{feed};
			$node->{feed} = sub {
				my ($client, $callback, $args, $pt) = @_;
				$cb->($client, sub {
					my $items = shift;
	
					$items->{items} = [ map { 
						$_->{image} ||= Slim::Web::ImageProxy::proxiedImage('mai/artist/' . $_->{id}, 'force');
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
	elsif ($retry) {
		$retry *= 2;
		$retry = $retry > 30 ? 30 : $retry;
		
		main::DEBUGLOG && $log->debug("Failed the hijacking... will try again in $retry seconds.");
		Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + $retry, \&_hijackArtistsMenu);
	}
} }

1;