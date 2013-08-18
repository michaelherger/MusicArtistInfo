package Plugins::MusicArtistInfo::TEN;

use strict;
use Date::Parse qw(str2time);
use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape uri_escape_utf8);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;

use constant BASE_URL => 'http://developer.echonest.com/api/v4/';
use constant MAX_HISTORY => 200;			# keep track of the 200 most recently played songs to pre-populate playlist history and prevent repetition

my $log = logger('plugin.musicartistinfo');
my $aid = '';

sub init {
	return if $aid;

	my $cache = Slim::Utils::Cache->new();

	(undef, $aid) = @_;

	$aid ||= $cache->get('mai_aid');
	$cache->set('mai_aid', $aid, 'never') if $aid;
}

sub getArtist {
	my ( $class, $cb, $args ) = @_;

	$class->searchArtists(sub {
		my $result = shift || {};
		my $artist = {};
		
		if ($result->{items}) {
			foreach ( @{$result->{items}} ) {
				# TODO - sanity check input, "smart matching" bjork/björk etc.
				if ( $_->{name} =~ /$args->{artist}/i ) {
					$artist = $_;
					last;
				}
			}
		}

		$cb->($artist);
	}, $args);
}

sub searchArtists {
	my ( $class, $cb, $args ) = @_;
	
	return _call('artist/search', {
		name => $args->{artist},
	}, sub {
		my $result = shift;
		my $items = [];
		
		if ( $result && $result->{response} ) {
			$items = $result->{response}->{artists} || [];
		}
		
		$cb->({ items => $items });
	});
}


sub getArtistNews {
	my ( $class, $cb, $args ) = @_;
	
	$class->getArtist(sub {
		my $artist = shift || {};

		return _call('artist/news', {
			id => $artist->{id},
			results => 100,
			high_relevance => 'true',
		}, sub {
			my $result = shift;
			my $items = [];
			
			if ( $result && $result->{response} ) {
				$items = [ map {
					$_->{date_found} = Slim::Utils::DateTime::shortDateF(
						str2time($_->{date_found})
					) if $_->{date_found};
					$_;
				} @{$result->{response}->{news}} ];
			}
			
			$cb->({ items => $items });
		});
	}, $args);
}

sub getArtistBlogs {
	my ( $class, $cb, $args ) = @_;
	
	$class->getArtist(sub {
		my $artist = shift || {};

		return _call('artist/blogs', {
			id => $artist->{id},
			results => 100,
			high_relevance => 'true',
		}, sub {
			my $result = shift;
			my $items = [];
			
			if ( $result && $result->{response} ) {
				$items = [ map {
					$_->{date_found} = Slim::Utils::DateTime::shortDateF(
						str2time($_->{date_found})
					) if $_->{date_found};
					$_;
				} @{$result->{response}->{blogs}} ];
			}
			
			$cb->({ items => $items });
		});
	}, $args);
}

sub getArtistVideos {
	my ( $class, $cb, $args ) = @_;
	
	$class->getArtist(sub {
		my $artist = shift || {};

		return _call('artist/video', {
			id => $artist->{id},
			results => 100,
		}, sub {
			my $result = shift;
			my $items = [];
			
			if ( $result && $result->{response} ) {
				$items = [ map {
					$_->{date_found} = Slim::Utils::DateTime::shortDateF(
						str2time($_->{date_found})
					) if $_->{date_found};
					$_;
				} @{$result->{response}->{video}} ];
			}
			
			$cb->({ items => $items });
		});
	}, $args);
}

sub _call {
	my ( $method, $args, $cb ) = @_;
	
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
	push @query, 'api_key=' . aid();

	my $params = join('&', @query);
	my $url = BASE_URL . $method;

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
	return ($aid =~ s/-//g) ? ($aid = uri_escape(pack('H*', $aid))) : $aid; 
}


1;