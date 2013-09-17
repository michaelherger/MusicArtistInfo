package Plugins::MusicArtistInfo::AlbumInfo;

use strict;

use Slim::Menu::AlbumInfo;
use Slim::Menu::TrackInfo;
use Slim::Menu::GlobalSearch;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Log;

use Plugins::MusicArtistInfo::ArtistInfo;
use Plugins::MusicArtistInfo::AllMusic;

my $log = logger('plugin.musicartistinfo');

sub init {
	Slim::Menu::GlobalSearch->registerInfoProvider( moremusicinfo => (
		func => \&searchHandler,
		after => 'moreartistinfo',
	) );

	Slim::Menu::AlbumInfo->registerInfoProvider( moremusicinfo => (
		func => \&albumInfoHandler,
		after => 'moreartistinfo',
	) );

	Slim::Menu::TrackInfo->registerInfoProvider( moremusicinfo => (
		func => \&trackInfoHandler,
		after => 'moreartistinfo',
	) );
}

sub getAlbumMenu {
	my ($client, $cb, $params, $args) = @_;
	
	$params ||= {};
	$args   ||= {};
	
	my $args2 = $params->{'album'} 
			|| _getAlbumFromAlbumId($params->{'album_id'}) 
			|| _getAlbumFromSongURL($client) unless $args->{url} || $args->{id};
			
	$args->{album}  ||= $args2->{album};
	$args->{artist} ||= $args2->{artist};
	
	main::DEBUGLOG && $log->debug("Getting album menu for " . $args->{album} . ' by ' . $args->{artist});
	
	my $pt = [$args];

	my $items = [ {
		name => cstring($client, 'PLUGIN_MUSICARTISTINFO_ALBUMDETAILS'),
		type => 'link',
		url  => \&getAlbumInfo,
		passthrough => $pt,
	},{
		name => cstring($client, 'PLUGIN_MUSICARTISTINFO_ALBUMCREDITS'),
		type => 'link',
		url  => \&getAlbumCredits,
		passthrough => $pt,
	} ];
	
	if ( !$params->{isButton} ) {
		unshift @$items, {
			name => cstring($client, 'PLUGIN_MUSICARTISTINFO_ALBUMREVIEW'),
			type => 'link',
			url  => \&getAlbumReview,
			passthrough => $pt,
		};
		
		push @$items, {
			name => cstring($client, 'PLUGIN_MUSICARTISTINFO_ALBUM_COVER'),
			type => 'link',
			url  => \&getAlbumCover,
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

	Plugins::MusicArtistInfo::AllMusic->getAlbumReview($client,
		sub {
			my $review = shift;
			my $items = [];
			
			if ($review->{error}) {
				$items = [{
					name => $review->{error},
					type => 'text'
				}]
			}
			elsif ($review->{review}) {
				my $content = '';
				if ( $params->{isWeb} ) {
					$content = '<h4>' . $review->{author} . '</h4>' if $review->{author};
					$content .= '<div><img src="' . $review->{image} . '"></div>' if $review->{image};
					$content .= $review->{review};
				}
				else {
					$content = $review->{author} . '\n\n' if $review->{author};
					$content .= $review->{reviewText};
				}
				
				# TODO - textarea not supported in button mode!
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

sub getAlbumCover {
	my ($client, $cb, $params, $args) = @_;

	my $getAlbumCoverCb = sub {
		my $cover = shift;
		my $items = [];
		
		if ($cover->{error}) {
			$items = [{
				name => $cover->{error},
				type => 'text'
			}]
		}
		elsif ($cover->{url}) {
			my $size = $cover->{width} || '';
			if ( $cover->{height} ) {
				$size .= ($size ? 'x' : '') . $cover->{height};
			}
			
			$size = " (${size}px)" if $size;
			
			push @$items, {
				name  => $cover->{author} . $size,
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
		
		$cb->($items);
	};

	Plugins::MusicArtistInfo::AllMusic->getAlbumCover($client,
		$getAlbumCoverCb,
		$args,
	);
}

sub getAlbumInfo {
	my ($client, $cb, $params, $args) = @_;
	
	Plugins::MusicArtistInfo::AllMusic->getAlbumDetails($client,
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
							{
								name => $_,
								type => 'text'
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

sub getAlbumCredits {
	my ($client, $cb, $params, $args) = @_;
	
	warn Data::Dump::dump($args);

	Plugins::MusicArtistInfo::AllMusic->getAlbumCredits($client,
		sub {
			my $credits = shift || {};
			
			my $items = [];
			
			if ($credits->{error}) {
				$items = [{
					name => $credits->{error},
					type => 'text'
				}]
			}
			elsif ( $credits->{items} ) {
				$items = [ map {
					my $name = $_->{name};
					
					if ($_->{credit}) {
						$name .= cstring($client, 'COLON') . ' ' . $_->{credit};
					}

					my $item = {
						name => $name,
						type => 'text',
					};
					
					if ($_->{url} || $_->{id}) {
						$item->{url} = \&Plugins::MusicArtistInfo::ArtistInfo::getArtistMenu;
						$item->{passthrough} = [{ 
							url => $_->{url},
							id  => $_->{id},
						}];
						$item->{type} = 'link';
					}
					
					$item;
				} @{$credits->{items}} ] if $credits->{items};
				
				main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($items));
			}
			
			$cb->($items);
		},
		$args,
	);
}

sub trackInfoHandler {
	my ( $client, $url, $track, $remoteMeta ) = @_;
	return _objInfoHandler( $client, $track->albumname || $remoteMeta->{album}, $track->artistName || $remoteMeta->{artist}, $url );
}

sub albumInfoHandler {
	my ( $client, $url, $album, $remoteMeta ) = @_;
	return _objInfoHandler( $client, $album->name || $remoteMeta->{name}, $album->contributor->name || $remoteMeta->{artist}, $url );
}

sub searchHandler {
	my ( $client, $tags ) = @_;
	return _objInfoHandler( $client, $tags->{search} );
}

sub _objInfoHandler {
	my ( $client, $album, $artist, $url ) = @_;

	$album = _getAlbumFromSongURL($client, $url) if !$album && $url;

	return unless $album;

	my $args = {
		album => {
			album  => $album,
			artist => $artist,
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
			main::INFOLOG && $log->info('Got Album/Artist from album ID: ' . $album->title . ' - ' . $album-contributor->name);
			
			return {
				artist => $album->contributor->name,
				album  => _cleanupAlbumName($album->title),			
			};
		}
	}
}

sub _getAlbumFromSongURL {
	my $client = shift;
	
	return unless $client;

	my %album;

	if (my $url = Slim::Player::Playlist::song($client)) {
		$url = $url->url;

		my $track = Slim::Schema->objectForUrl($url);

		my ($artist, $album);
		$artist = $track->artist->name if (defined $track->artist);
		$album  = $track->album->title if (defined $track->album);

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
			};
		}
	}
}

sub _cleanupAlbumName {
	my $album = shift;
	
	main::INFOLOG && $log->info("Cleaning up album name: '$album'");

	# remove everything between () or []... But don't for PG's eponymous first four albums :-)
	$album =~ s/[\(\[].*?[\)\]]//g if $album !~ /Peter Gabriel \[[1-4]\]/i;
	
	# remove stuff like "CD02", "1 of 2"
	$album =~ s/\b(disc \d+ of \d+)\b//ig;
	$album =~ s/\d+\/\d+//ig;
	$album =~ s/\b(cd\s*\d+|\d+ of \d+|disc \d+)\b//ig;
	# remove trailing non-word characters
	$album =~ s/[\s\W]{2,}$//;
	$album =~ s/\s*$//;

	main::INFOLOG && $log->info("Album name cleaned up:  '$album'");

	return $album;
}


1;