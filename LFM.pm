package Plugins::MusicArtistInfo::LFM;

use strict;
use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape uri_escape_utf8);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Text;
use Slim::Utils::Strings qw(string cstring);

use constant BASE_URL => 'http://ws.audioscrobbler.com/2.0/';

my $log = logger('plugin.musicartistinfo');
my $aid = 'c6abc51e847b91aba0de2ede33875e24';

sub getAlbumCover {
	my ( $class, $client, $cb, $args ) = @_;
	
	$class->getAlbum(sub {
		my $albumInfo = shift;
		my $result = {};
		
		if ( $albumInfo && $albumInfo->{album} && (my $image = $albumInfo->{album}->{image}) ) {
			if ( ref $image eq 'ARRAY' ) {
				$result->{images} = [ reverse grep {
					$_
				} map {
					my ($size) = $_->{'#text'} =~ m{/(34|64|126|174|252|500|\d+x\d+)s?/}i;
					
					# ignore sizes smaller than 300px
					{
						author => 'Last.fm',
						url    => $_->{'#text'},
						width  => $size || $_->{size},
					} if $_->{'#text'} && (!$size || $size*1 >= 300);
				} @{$image} ];
			}
		}

		if ( !$result->{images} ) {
			$result->{error} ||= cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND');
		}
		
		$cb->($result);
	}, $args);
}

sub getAlbum {
	my ( $class, $cb, $args ) = @_;

	# last.fm doesn't try to be smart about names: "the beatles" != "beatles" - don't punish users with correct tags
	# this is an ugly hack, but we can't set the ignoredarticles pref, as this triggers a rescan...
	my $ignoredArticles = $Slim::Utils::Text::ignoredArticles;
	%Slim::Utils::Text::caseArticlesCache = ();
	$Slim::Utils::Text::ignoredArticles = qr/^\s+/;

	my $artist = Slim::Utils::Text::ignoreCaseArticles($args->{artist}, 1);
	my $album  = Slim::Utils::Text::ignoreCaseArticles($args->{album}, 1);
	my $albumLC= lc( $args->{album} );

	$Slim::Utils::Text::ignoredArticles = $ignoredArticles;
	
	if (!$artist || !$album) {
		$cb->();
		return;
	}

	_call({
		method => 'album.getinfo',
		artist => $artist,
		album  => $album,
		autocorrect => 1,
	}, sub {
		$cb->(shift);
	});
}


sub _call {
	my ( $args, $cb ) = @_;
	
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
	push @query, 'api_key=' . aid(), 'format=json';

	my $params = join('&', @query);
	my $url = BASE_URL;

	main::INFOLOG && $log->is_info && $log->info(_debug( "Async API call: GET $url?$params" ));
	
	my $cb2 = sub {
		my $response = shift;
		
		main::DEBUGLOG && $log->is_debug && $response->code !~ /2\d\d/ && $log->debug(_debug(Data::Dump::dump($response, @_)));
		my $result = eval { from_json( $response->content ) };
	
		$result ||= {};
		
		if ($@) {
			 $log->error($@);
			 $result->{error} = $@;
		}

		main::DEBUGLOG && $log->is_debug && warn Data::Dump::dump($result);
			
		$cb->($result);
	};
	
	Slim::Networking::SimpleAsyncHTTP->new( 
		$cb2, 
		$cb2, 
		{
			timeout => 15,
			cache   => 1,
		}
	)->get($url . '?' . $params);
}

sub _debug {
	my $msg = shift;
	$msg =~ s/$aid/\*/gi if $aid;
	return $msg;
}

sub aid {
	if ( $_[1] ) {
		$aid = $_[1];
		$aid =~ s/-//g;
	}
	return $aid; 
}

1;