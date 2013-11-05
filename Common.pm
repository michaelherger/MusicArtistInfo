package Plugins::MusicArtistInfo::Common;

use strict;
use File::Spec::Functions qw(catdir);

use Slim::Utils::Log;

use constant CAN_IMAGEPROXY => (Slim::Utils::Versions->compareVersions($::VERSION, '7.8.0') >= 0);

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.musicartistinfo',
	defaultLevel => 'ERROR',
	description  => 'PLUGIN_MUSICARTISTINFO',
} );

my $ua;

sub cleanupAlbumName {
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

sub imageInFolder {
	my ($folder, $name) = @_;

	#main::DEBUGLOG && $log->debug("Trying to find artwork in $folder");
	
	my $img;
		
	if ( opendir(DIR, $folder) ) {
		while (readdir(DIR)) {
			if (/$name\.(?:jpe?g|png|gif)$/i) {
				$img = catdir($folder, $_);
				last;
			}
		}
		closedir(DIR);
	}
	else {
		$log->error("Unable to open dir '$folder'");
	}

	return $img;
}

sub call {
	my ($class, $url, $cb, $params) = @_;

	main::INFOLOG && $log->is_info && $log->info((main::SCANNER ? 'Sync' : 'Async') . " API call: GET $url" );
	
	$params->{timeout} ||= 15;
	
	if (main::SCANNER) {
		require LWP::UserAgent;
		$ua ||= LWP::UserAgent->new(
			agent   => Slim::Utils::Misc::userAgentString(),
			timeout => $params->{timeout},
		);
		
		my $request = HTTP::Request->new( GET => $url );
		my $response = $ua->request( $request );
		
		$cb->($response);
	}
	else {
		Slim::Networking::SimpleAsyncHTTP->new( 
			$cb,
			$cb,
			$params
		)->get($url);
	}
}



1;