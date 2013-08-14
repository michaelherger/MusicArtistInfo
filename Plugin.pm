package Plugins::MusicArtistInfo::Plugin;

use strict;
use base qw(Slim::Plugin::OPMLBased);

use vars qw($VERSION);
#use Digest::MD5 qw(md5_hex);
#use JSON::XS::VersionOneAndTwo;
#use Scalar::Util qw(blessed);

#use Slim::Menu::TrackInfo;
#use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string cstring);
#use Slim::Utils::Timers;

use Plugins::MusicArtistInfo::AllMusic;

use constant PLUGIN_TAG => 'musicartistinfo';

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.musicartistinfo',
	defaultLevel => 'ERROR',
	description  => 'PLUGIN_MUSICARTISTINFO',
} );

#my $prefs = preferences('server');

sub initPlugin {
	my $class = shift;
	
	$VERSION = $class->_pluginDataFor('version');
	
	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => PLUGIN_TAG,
		menu   => 'plugins',
#		is_app => 1,
		weight => 1,
	);
}

# don't add this plugin to the Extras menu
sub playerMenu { 'PLUGINS' }

sub handleFeed {
	my ($client, $cb, $params, $args) = @_;
	
	getArtistMenu($client, $cb, $params)
	
	$cb->({
		items => [
			{
				name => cstring($client, 'PLUGIN_MUSICARTISTINFO_ARTISTINFO'),
				type => 'link',
				url  => \&getArtistMenu,
			},
		],
	});
}

sub getArtistMenu {
	my ($client, $cb, $params) = @_;

	my $items = [
		{
			name => cstring($client, 'PLUGIN_MUSICARTISTINFO_BIOGRAPHY'),
			type => 'link',
			url  => \&getBiography,
			passthrough => [{
				artist => 'björk' 
			}],
		},
		{
			name => cstring($client, 'PLUGIN_MUSICARTISTINFO_ARTISTDETAILS'),
			type => 'link',
			url  => \&getArtistInfo,
			passthrough => [{
				artist => 'sting'
			}],
		},
		{
			name => cstring($client, 'PLUGIN_MUSICARTISTINFO_ARTISTPICTURES'),
			type => 'link',
			url  => \&getArtistPhotos,
			passthrough => [{
				artist => 'peter gabriel'
			}],
		},
		{
			name => cstring($client, 'PLUGIN_MUSICARTISTINFO_RELATED_ARTISTS'),
			type => 'link',
			url  => \&getRelatedArtists,
			passthrough => [{
				artist => 'bob dylan'
			}],
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
			
			if ($bio->{bio}) {
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
			my $photos = shift;
			my $items = [];

			if ( $photos ) {
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
				} @$photos ];
			}
									
			$cb->($items);
		},
		$args,
	);
}

sub getArtistInfo {
	my ($client, $cb, $params, $args) = @_;

	Plugins::MusicArtistInfo::AllMusic->getArtistDetails($client,
		sub {
			my $details = shift;
			my $items = [];

			if ( @$details ) {
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
				} @$details ];
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

			if ( @$relations ) {
				$items = [ map {
					my ($k, $v) = each %{$_};
					
					{
						name  => $k,
						type  => 'outline',
						items => [ map {
							{ 
								name => $_->{name},
								type => 'text'
							 }
						} @$v ],
					}
				} @$relations ];
			}
									
			$cb->($items);
		},
		$args,
	);
}

1;