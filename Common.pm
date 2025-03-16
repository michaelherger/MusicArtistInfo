package Plugins::MusicArtistInfo::Common;

use strict;

use Exporter::Lite;
use File::Spec::Functions qw(catdir);
use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape uri_escape_utf8);

use Slim::Utils::Cache;
use Slim::Utils::Log;

BEGIN {
	use Slim::Music::Artwork;
	use constant CAN_IMAGEPROXY => (Slim::Utils::Versions->compareVersions($::VERSION, '7.8.0') >= 0);
	use constant CAN_ONLINE_LIBRARY => (Slim::Utils::Versions->compareVersions($::VERSION, '8.0.0') >= 0);
	use constant CAN_LMS_ARTIST_ARTWORK => (Slim::Utils::Versions->compareVersions($::VERSION, '9.1.0') >= 0 && Slim::Music::Artwork->can('generateImageId')) ? 1 : 0;
	use constant CAN_DISCOGS => 0;
	use constant CAN_LFM => 1;
	use constant CLICOMMAND => 'musicartistinfo';

	use Exporter::Lite;
	our @EXPORT_OK = qw( CLICOMMAND CAN_IMAGEPROXY CAN_LMS_ARTIST_ARTWORK CAN_ONLINE_LIBRARY CAN_DISCOGS CAN_LFM );
}

my $cache = Slim::Utils::Cache->new();
my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.musicartistinfo',
	defaultLevel => 'WARN',
	description  => 'PLUGIN_MUSICARTISTINFO',
} );

my $ua;

sub cleanupAlbumName {
	my $album = shift;

	# keep a backup copy, in case cleaning would wipe all of it
	my $fullAlbum = $album;

	main::INFOLOG && $log->info("Cleaning up album name: '$album'");

	# remove everything between (), {} or []... But don't for PG's eponymous first four albums :-)
	$album =~ s/(?<!^)[(\[{].*?[}\])]//g if $album !~ /Peter Gabriel .*\b(?:[1-4]|Car|Scratch|Melt|Security)\b/i && $album !~ /beatles.*white album/i;

	# remove stuff like "CD02", "1 of 2"
	$album =~ s/\b(disc \d+ of \d+)\b//ig;
	# would break Justin Timberlake's "The 20/20 Experience"
	# $album =~ s/\d+\/\d+//ig;
	$album =~ s/\b(cd\s*\d+|\d+ of \d+|disc \d+)\b//ig;
	$album =~ s/- live\b//i;

	# remove additional information added by the Radio Now Playing plugin
	$album =~ s/\|.*//;

	# remove trailing non-word characters
	$album =~ s/[\s\W]{2,}$//;
	$album =~ s/\s*$//;
	$album =~ s/^\s*//;
	$album =~ s/(\s)\s+/$1/g;

	main::INFOLOG && $log->info("Album name cleaned up:  '$album'");

	return $album || $fullAlbum;
}

sub matchAlbum {
	my ($class, $wanted, $candidate, $strict) = @_;

	my $artist = Slim::Utils::Text::ignoreCaseArticles($wanted->{artist}, 1);
	my $album  = Slim::Utils::Text::ignoreCaseArticles($wanted->{album}, 1);

	return if !$artist || !$album;

	my $albumLC = lc( $wanted->{album} );
	my $artist2 = $wanted->{artist};
	$artist2 =~ s/&/and/g;
	$artist2 = Slim::Utils::Text::ignoreCaseArticles($artist2, 1);

	my $artistName = Slim::Utils::Text::ignoreCaseArticles($candidate->{artist}, 1);

	if ( $artistName =~ /\Q$artist\E/i || $artistName =~ /\Q$artist2\E/i ) {
		if ( lc($candidate->{album}) eq $albumLC ) {
			return 1;
		}

		if ( !$strict && Slim::Utils::Text::ignoreCaseArticles($candidate->{album}, 1) =~ /\Q$album\E/i ) {
			return 1;
		}
	}

	return;
}

my @HEADER_DATA = map {
	# s/=*$|\s//sg;
	MIME::Base64::decode_base64($_);
} <Plugins::MusicArtistInfo::Common::DATA>;

$HEADER_DATA[CAN_DISCOGS] = eval { from_json($HEADER_DATA[CAN_DISCOGS]) };

sub imageInFolder {
	my ($folder, @names) = @_;

	return unless $folder && @names;

	main::INFOLOG && $log->info("Trying to find artwork in $folder");

	return fileInFolder($folder, ['jpg', 'JPG', 'jpeg', 'JPEG', 'png', 'PNG', 'gif', 'GIF'], @names);
}

sub fileInFolder {
	my ($folder, $extensions, @names) = @_;

	my $file;
	my %seen;

	foreach my $name (@names) {
		next if $seen{$name}++;
		foreach my $ext (@$extensions) {
			my $candidate = catdir($folder, $name . ".$ext");

			if (-f $candidate) {
				$file = $candidate;
				last;
			}
		}

		last if $file;
	}

	return $file;
}

sub getLocalnameVariants {
	my ($name) = @_;

	# Remove wildcards and other stuff potentially conflicting with file system limitations
	# For whatever reason those aren't removed by S::U::Misc::cleanupFilename()
	$name =~ s/[:?*]//g;

	my @candidates = map {
		(
			$_,
			Slim::Utils::Unicode::utf8encode($_),
			Slim::Utils::Text::ignorePunct($_)
		);
	} (Slim::Utils::Misc::cleanupFilename($name), $name);
	push @candidates, Slim::Utils::Unicode::utf8toLatin1Transliterate($candidates[-1]);

	# de-dupe results
	my %seen;
	return [ grep { !$seen{$_}++ } @candidates ];
}

sub call {
	my ($class, $url, $cb, $params) = @_;

	$url =~ s/\?$//;

	main::INFOLOG && $log->is_info && $log->info((main::SCANNER ? 'Sync' : 'Async') . ' API call: GET ' . _debug($url) );

	# we can get a list of error codes which we'll ignore in the error messaging - lyrics often end in 404
	my $noWarn = join('|', grep /\d{3}/, @{delete $params->{ignoreError} || []});
	my $wantsError = delete $params->{wantError};

	$params->{timeout} ||= 15;
	my %headers = %{delete $params->{headers} || {}};

	my $cb2 = sub {
		my ($response, $error) = @_;

		main::DEBUGLOG && $log->is_debug && $response->code !~ /2\d\d/ && $log->debug(_debug(Data::Dump::dump($response, @_)));

		my $result;

		if ($error) {
			$log->error(sprintf("Failed to call %s: %s", _debug($response->url), $error)) if (!$noWarn || $noWarn !~ /^($noWarn)/) || (main::INFOLOG && $log->is_info) || (main::DEBUGLOG && $log->is_debug);
			$result = {};
			$result->{error} = $error if $wantsError;
		}

		$result ||= eval {
			my $content = $response->can('decoded_content')
				? $response->decoded_content
				: $response->content;

			if ( $response->headers->content_type =~ /xml/ ) {
				require XML::Simple;
				XML::Simple::XMLin( $content );
			}
			elsif ( $response->headers->content_type =~ /json/ ) {
				from_json( $content );
			}
			else {
				$content;
			}
		};

		$result ||= {};

		if ($@) {
			 $log->error($@);
			 $result->{error} = $@;
		}

		main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($result));

		$cb->($result, $response->headers);
	};

	if (main::SCANNER) {
		my $cacheKey = "mai_$url";

		my $cached = $cache->get($cacheKey);
		if ($cached && ref $cached && ref $cached eq 'HTTP::Response') {
			$cached->header('x-discogs-ratelimit-remaining' => 999) if defined $cached->header('x-discogs-ratelimit-remaining');
			return $cb2->($cached);
		}

		$ua ||= $class->getUA({
			timeout => $params->{timeout}
		});

		# our sometimes outdated HTML::Parser seems to trip over some headers - ignore them...
		$ua->parse_head($url =~ /last\.fm/ ? 0 : 1);

		my $response = $ua->get($url, %headers);

		$cache->set($cacheKey, $response, $params->{expires} || '1d') if $response->code == 200;

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

sub getUA { if (main::SCANNER) {
	my ($class, $args) = @_;

	require HTTP::Message;
	require LWP::UserAgent;

	eval {
		require IO::Socket::SSL;

		# our old LWP::UserAgent doesn't support ssl_opts yet
		IO::Socket::SSL::set_defaults(
			SSL_verify_mode => 0
		);
	};

	if ($@) {
		$log->warn("Unable to load IO::Socket::SSL, will try connecting to SSL servers in non-SSL mode\n$@\n");
	}

	my $ua = LWP::UserAgent->new(
		agent   => Slim::Utils::Misc::userAgentString(),
		timeout => $args->{timeout} || 15,
	);

	if (my $encodings = eval { scalar HTTP::Message::decodable() }) {
		$ua->default_header('Accept-Encoding' => $encodings);
	}

	return $ua;
}
else {
	$log->warn('getUA() is only available in the scanner!');
} }

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

	return sort @query;
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
eyJBdXRob3JpemF0aW9uIjoiRGlzY29ncyBrZXk9aFd3c2RBamFQQmhIQVVqZlJ2RnosIHNlY3JldD1ZVWFtamJPVnJUdlpDQnZJVHRkc3NKZ2hGU1VkbllReCJ9
YXBpX2tleT1jNmFiYzUxZTg0N2I5MWFiYTBkZTJlZGUzMzg3NWUyNA