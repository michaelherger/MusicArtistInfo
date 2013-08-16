package Plugins::MusicArtistInfo::Plugin;

use strict;
use base qw(Slim::Plugin::Base);

use vars qw($VERSION);

#use Slim::Menu::TrackInfo;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string cstring);

use Plugins::MusicArtistInfo::ArtistInfo;
use Plugins::MusicArtistInfo::AlbumInfo;

use constant PLUGIN_TAG => 'musicartistinfo';

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.musicartistinfo',
	defaultLevel => 'ERROR',
	description  => 'PLUGIN_MUSICARTISTINFO',
} );

sub initPlugin {
	my $class = shift;
	
	$VERSION = $class->_pluginDataFor('version');
	
	Plugins::MusicArtistInfo::AlbumInfo->init();
	Plugins::MusicArtistInfo::ArtistInfo->init($class->_pluginDataFor('aid'));
	
	$class->SUPER::initPlugin(shift);
#		feed   => \&handleFeed,
#		tag    => PLUGIN_TAG,
#		menu   => 'plugins',
#		is_app => 1,
#		weight => 1,
#	);
}

# don't add this plugin to the Extras menu
sub playerMenu {}

#sub handleFeed {
#	my ($client, $cb, $params, $args) = @_;
#	
#	$cb->({
#		items => [
#			{
#				name => cstring($client, 'PLUGIN_MUSICARTISTINFO_ARTISTINFO'),
#				type => 'link',
#				url  => sub {
#					Plugins::MusicArtistInfo::ArtistInfo::getArtistMenu(@_);
#				},
#			},
#			{
#				name => cstring($client, 'PLUGIN_MUSICARTISTINFO_ALBUMINFO'),
#				type => 'link',
#				url  => sub {
#					Plugins::MusicArtistInfo::AlbumInfo::getAlbumMenu(@_);
#				},
#			},
#		],
#	});
#}

1;