package Plugins::MusicArtistInfo::TEN;

use strict;
use Date::Parse qw(str2time);
use URI::Escape qw(uri_escape);

use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);

use Plugins::MusicArtistInfo::Common;

use constant BASE_URL => 'http://developer.echonest.com/api/v4/';

my $log = logger('plugin.musicartistinfo');
my $aid = '';

sub init {
	$aid = $_[1]->_pluginDataFor('id1');
}

sub getArtist {
	my ( $class, $cb, $args ) = @_;

	$class->searchArtists(sub {
		my $result = shift || {};
		my $artist = {};
		my $searchArtist = Slim::Utils::Text::ignoreCaseArticles($args->{artist}, 1);
		my $searchArtistLC = lc( $args->{artist} );
		
		if ($result->{items}) {
			foreach ( @{$result->{items}} ) {
				if ( lc( $_->{name} ) eq $searchArtistLC ) {
					$artist = $_;
					last;
				}
				
				if ( !$artist && Slim::Utils::Text::ignoreCaseArticles($_->{name}, 1) =~ /$searchArtist/i ) {
					$artist = $_;
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


sub getArtistPhotos {
	my ( $class, $cb, $args ) = @_;

	my $key = 'ten_artist_photos_' . URI::Escape::uri_escape_utf8($args->{artist});
	my $cache = Slim::Utils::Cache->new;	
	if ( my $cached = $cache->get($key) ) {
		$cb->($cached);
		return;
	}

	$class->getArtist(sub {
		my $artist = shift || {};

		return _call('artist/images', {
			id => $artist->{id},
			results => 100,
			license => [qw(gpl lgpl cc-by-nc-nd cc-by-nc-sa unknown cc-by cc-by-sa cc-by-nd cc-by-nc cc-sa gfdl public-domain)],
		}, sub {
			my $result = shift;
			my $items = [];

			if ( $result && $result->{response} ) {
				foreach ( @{$result->{response}->{images}} ) {
					next if $_->{license}->{attribution} =~ /youtube|myspace/i;
					
					my $author = $_->{license}->{attribution};
					
					if ($_->{url} =~ /last\.fm/) { $author = 'Last.fm'; }
					elsif ($_->{url} =~ /images-amazon/) { $author = 'Amazon'; }
					elsif ($_->{url} =~ /wikimedia/) { $author = $_->{license}->{attribution} . ' (Wikipedia)'; }
					
					$_->{url} =~ s/\._SL\d\d\d_\./._SL600_./;
					push @$items, {
						author => $author,
						url    => $_->{url},
						height => $_->{height},
						width  => $_->{width},
					};
				}
			}

			$cache->set($key, { photos => $items });
			$cb->({ photos => $items });
		});
	}, $args);
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
					$_->{summary} =~ s/^Printable version\s*//i;		# TEN doesn't parse this out
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

sub getArtistURLs {
	my ( $class, $cb, $args ) = @_;
	
	$class->getArtist(sub {
		my $artist = shift || {};

		return _call('artist/urls', {
			id => $artist->{id},
#			results => 100,
		}, sub {
			my $result = shift;
			my $items = [];
			
			if ( $result && $result->{response} && (my $urls = $result->{response}->{urls}) ) {
				my $official = string('PLUGIN_MUSICARTISTINFO_OFFICIAL_SITE');

				my %sources = (
					lastfm   => 'last.fm',
					aolmusic => 'AOL Music',
					itunes   => 'iTunes',
					mb       => 'MusicBrainz',
					wikipedia=> 'Wikipedia',
					official => $official,
				);
				
				while ( my ($name, $url) = each %$urls ) {
					my ($source) = $name =~ /(.*)_url/i;
					
					if ($sources{$source}) {
						$source = $sources{$source};
					}
					
					push @$items, {
						name => $source,
						url  => $url,
					};
				}
				
				$items = [ sort {
					if ( $a->{name} eq $official ) { -1; }
					elsif ( $b->{name} eq $official ) { 1; }
					else { lc($a->{name}) cmp lc($b->{name}); }
				} @$items ];
			}
			
			$cb->({ items => $items });
		});
	}, $args);
}

sub _call {
	my ( $method, $args, $cb ) = @_;
	
	Plugins::MusicArtistInfo::Common->call(
		BASE_URL . $method . '?' . join( '&', @{Plugins::MusicArtistInfo::Common->getQueryString($args)}, 'api_key=' . aid() ), 
		$cb,
		{ cache => 1 }
	);
}

sub aid {
	return ($aid =~ s/-//g) ? ($aid = uri_escape(pack('H*', $aid))) : $aid; 
}


1;