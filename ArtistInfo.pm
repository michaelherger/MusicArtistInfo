package Plugins::MusicArtistInfo::ArtistInfo;

use strict;

use Slim::Menu::ArtistInfo;
use Slim::Menu::AlbumInfo;
use Slim::Menu::TrackInfo;
use Slim::Menu::GlobalSearch;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Log;

use Plugins::MusicArtistInfo::AllMusic;
use Plugins::MusicArtistInfo::TEN;

use constant CLICOMMAND => 'musicartistinfo'; 

my $log = logger('plugin.musicartistinfo');

sub init {
#                                                                |requires Client
#                                                                |  |is a Query
#                                                                |  |  |has Tags
#                                                                |  |  |  |Function to call
#                                                                C  Q  T  F
	Slim::Control::Request::addDispatch([CLICOMMAND, 'videos'], [1, 1, 1, \&getArtistWeblinksCLI]);
	Slim::Control::Request::addDispatch([CLICOMMAND, 'blogs'], [1, 1, 1, \&getArtistWeblinksCLI]);
	Slim::Control::Request::addDispatch([CLICOMMAND, 'news'], [1, 1, 1, \&getArtistWeblinksCLI]);

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

	Plugins::MusicArtistInfo::TEN->init($_[1]);
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
			type => 'link',
			url  => \&getArtistPhotos,
			passthrough => $pt,
		};

		# XMLBrowser for Jive can't handle weblinks - need custom handling there to show videos, blogs etc.
		# don't show blog/news summaries on iPeng, but link instead. And show videos!
		if ($params->{isControl} && $client->controllerUA =~ /iPeng/i)  {
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
			} if $params->{isWeb};
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

	Plugins::MusicArtistInfo::AllMusic->getArtistPhotos($client,
		sub {
			my $photos = shift || {};
			my $items = [];

			if ($photos->{error}) {
				$items = [{
					name => $photos->{error},
					type => 'text'
				}]
			}
			elsif ($photos->{items}) {
				$items = [ map {
					my $credit = cstring($client, 'BY') . ' ';
					{
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
				} @{$photos->{items}} ];
			}
									
			$cb->($items);
		},
		$args,
	);
}

sub getArtistInfo {
	my ($client, $cb, $params, $args) = @_;
	
	warn Data::Dump::dump($args);

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
			my $item = {
				name  => $_->{name} || $_->{title},
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
	if ($request->isNotQuery([[CLICOMMAND], ['videos', 'blogs', 'news']]) || !$request->client()) {
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
	my $return = _objInfoHandler( $client, $track->artistName || $remoteMeta->{artist}, $url );
}

sub artistInfoHandler {
	my ( $client, $url, $artist, $remoteMeta ) = @_;
	my $return = _objInfoHandler( $client, $artist->name || $remoteMeta->{artist}, $url );
}

sub albumInfoHandler {
	my ( $client, $url, $album, $remoteMeta ) = @_;
	my $return = _objInfoHandler( $client, $album->contributor->name || $remoteMeta->{artist}, $url );
}

sub searchHandler {
	my ( $client, $tags ) = @_;
	my $return = _objInfoHandler( $client, $tags->{search} );
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

	if ($trackId) {
		my $track = Slim::Schema->resultset("Track")->find($trackId);

		return unless $track;

		my $artist = $track->artist->name if $track->artist;

		main::DEBUGLOG && $artist && $log->debug("Got artist name from song ID: '$artist'");

		return $artist;
	}
}

sub _getArtistFromArtistId {
	my $artistId = shift;

	if (defined($artistId)) {
		my $artistObj = Slim::Schema->resultset("Contributor")->find($artistId);

		my $artist = $artistObj->name if $artistObj;
	
		main::DEBUGLOG && $artist && $log->debug("Got artist name from artist ID: '$artist'");

		return $artist;
	}
}

sub _getArtistFromAlbumId {
	my $albumId = shift;

	if (defined($albumId)) {
		my $album = Slim::Schema->resultset("Album")->find($albumId);
		
		my $artist = $album->contributor->name if $album;

		main::DEBUGLOG && $artist && $log->debug("Got artist name from album ID: '$artist'");
	
		return $artist;
	}
}

1;