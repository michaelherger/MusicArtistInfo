package Plugins::MusicArtistInfo::ArtistInfo;

use strict;

use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Log;
use Plugins::MusicArtistInfo::AllMusic;

my $log = logger('plugin.musicartistinfo');

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

	my $items = [
		{
			name => cstring($client, 'PLUGIN_MUSICARTISTINFO_BIOGRAPHY'),
			type => 'link',
			url  => \&getBiography,
			passthrough => $pt,
		},
		{
			name => cstring($client, 'PLUGIN_MUSICARTISTINFO_ARTISTDETAILS'),
			type => 'link',
			url  => \&getArtistInfo,
			passthrough => $pt,
		},
		{
			name => cstring($client, 'PLUGIN_MUSICARTISTINFO_ARTISTPICTURES'),
			type => 'link',
			url  => \&getArtistPhotos,
			passthrough => $pt,
		},
		{
			name => cstring($client, 'PLUGIN_MUSICARTISTINFO_RELATED_ARTISTS'),
			type => 'link',
			url  => \&getRelatedArtists,
			passthrough => $pt,
		},
	];
	
	$cb->({
		items => $items,
	});
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


sub _getArtistFromSongURL {
	my $client = shift;

	return unless $client;

	if ( my $url = Slim::Player::Playlist::song($client) ) {
		$url = $url->url;
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