package Plugins::MusicArtistInfo::API;

use strict;
use URI::Escape qw(uri_escape_utf8);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use constant ARTISTIMAGESEARCH_URL => 'https://mai-api.nixda.ch/artist/%s/picture';

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.musicartistinfo');
my $prefs = preferences('plugin.musicartistinfo');

sub getArtistPhoto {
	my ( $class, $client, $cb, $args ) = @_;

	my $query = '?mbid=' . $args->{mbid} if $args->{mbid};

	Plugins::MusicArtistInfo::Common->call(
		sprintf(ARTISTIMAGESEARCH_URL, uri_escape_utf8($args->{artist})) . $query,
		sub {
			my ($result) = @_;

			my $photo;

			if ($result && ref $result && (my $url = $result->{picture})) {
				$photo = {
					url => $url,
				};
			}

			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($photo));

			$cb->($photo);
		},{
			cache => 1,
			expires => 86400,	# force caching
			# ignoreError => [404],
		}
	);
}


1;