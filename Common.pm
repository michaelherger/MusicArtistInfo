package Plugins::MusicArtistInfo::Common;

use strict;
use File::Spec::Functions qw(catdir);
use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape uri_escape_utf8);

use Slim::Utils::Log;

use constant CAN_IMAGEPROXY => (Slim::Utils::Versions->compareVersions($::VERSION, '7.8.0') >= 0);
use constant CAN_DISCOGS => 0;
use constant CAN_LFM => 1;

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.musicartistinfo',
	defaultLevel => 'ERROR',
	description  => 'PLUGIN_MUSICARTISTINFO',
} );

my $ua;

sub cleanupAlbumName {
	my $album = shift;
	
	# keep a backup copy, in case cleaning would wipe all of it
	my $fullAlbum = $album;
	
	main::INFOLOG && $log->info("Cleaning up album name: '$album'");

	# remove everything between () or []... But don't for PG's eponymous first four albums :-)
	$album =~ s/[\(\[].*?[\)\]]//g if $album !~ /Peter Gabriel .*\b[1-4]\b/i;
	
	# remove stuff like "CD02", "1 of 2"
	$album =~ s/\b(disc \d+ of \d+)\b//ig;
	$album =~ s/\d+\/\d+//ig;
	$album =~ s/\b(cd\s*\d+|\d+ of \d+|disc \d+)\b//ig;
	$album =~ s/- live\b//i;

	# remove trailing non-word characters
	$album =~ s/[\s\W]{2,}$//;
	$album =~ s/\s*$//;

	main::INFOLOG && $log->info("Album name cleaned up:  '$album'");

	return $album || $fullAlbum;
}

my @HEADER_DATA = map {
	# s/=*$|\s//sg;
	MIME::Base64::decode_base64($_);
} <Plugins::MusicArtistInfo::Common::DATA>;

$HEADER_DATA[CAN_DISCOGS] = eval { from_json($HEADER_DATA[CAN_DISCOGS]) };

sub imageInFolder {
	my ($folder, @names) = @_;
	
	return unless $folder && @names;

	#main::DEBUGLOG && $log->debug("Trying to find artwork in $folder");
	
	my $img;
	my %seen;
	
	foreach my $name (@names) {
		next if $seen{$name}++;
		foreach my $ext ('jpg', 'JPG', 'jpeg', 'png', 'gif') {
			my $file = catdir($folder, $name . ".$ext");

			if (-f $file) {
				$img = $file;
				last;
			}
		}
		
		last if $img;
	}

	return $img;
}

sub call {
	my ($class, $url, $cb, $params) = @_;

	$url =~ s/\?$//;

	main::INFOLOG && $log->is_info && $log->info((main::SCANNER ? 'Sync' : 'Async') . ' API call: GET ' . _debug($url) );
	
	$params->{timeout} ||= 15;
	my %headers = %{delete $params->{headers} || {}};
	
	my $cb2 = sub {
		my ($response, $error) = @_;

		main::DEBUGLOG && $log->is_debug && $response->code !~ /2\d\d/ && $log->debug(_debug(Data::Dump::dump($response, @_)));
		
		my $result;
		
		if ($error) {
			$log->error(sprintf("Failed to call %s: %s", _debug($response->url), $error));
			$result = {};
		}
		
		$result ||= eval {
			if ( $response->headers->content_type =~ /xml/ ) {
				require XML::Simple;
				XML::Simple::XMLin( $response->content );
			} 
			else {
				from_json( $response->content ); 
			}
		};
	
		$result ||= {};
		
		if ($@) {
			 $log->error($@);
			 $result->{error} = $@;
		}

		main::DEBUGLOG && $log->is_debug && warn Data::Dump::dump($result);
			
		$cb->($result);
	};
	
	if (main::SCANNER) {
		require LWP::UserAgent;
		$ua ||= LWP::UserAgent->new(
			agent   => Slim::Utils::Misc::userAgentString(),
			timeout => $params->{timeout},
		);
		
		my $request = HTTP::Request->new( GET => $url );
		my $response = $ua->request( $request );
		
		$cb2->($response);
	}
	else {
		Slim::Networking::SimpleAsyncHTTP->new( 
			$cb2,
			$cb2,
			$params
		)->get($url, %headers);
	}
}

sub getQueryString {
	my ($class, $args) = @_;

	$args ||= {};
	my @query;
	
	while (my ($k, $v) = each %$args) {
		next if $k =~ /^_/;		# ignore keys starting with an underscore
		
		if (ref $v eq 'ARRAY') {
			foreach (@$v) {
				push @query, $k . '=' . uri_escape_utf8($_);
			}
		}
		else {
			push @query, $k . '=' . uri_escape_utf8($v);
		}
	}
	
	return \@query;
}

sub _debug {
	my $msg = shift;
	$msg =~ s/api_key=.*?(&|$)//gi;
	return $msg;
}

sub getHeaders {
	return $HEADER_DATA[{'discogs' => CAN_DISCOGS, 'lfm' => CAN_LFM}->{$_[1]}]
}

1;

__DATA__
eyJBdXRob3JpemF0aW9uIjoiRGlzY29ncyB0b2tlbj1nclB1Z2NNUGRlTXpiZnlNbm1XUHpyeVd6SEltUlhoc1p0ZXN4SHREIn0
YXBpX2tleT1jNmFiYzUxZTg0N2I5MWFiYTBkZTJlZGUzMzg3NWUyNA