package Plugins::MusicArtistInfo::Wikipedia;

use strict;

use HTML::FormatText;
use Text::Levenshtein;
use URI::Escape qw(uri_escape_utf8);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);

use Plugins::MusicArtistInfo::Common qw(CAN_IMAGEPROXY);

use constant MIN_REVIEW_SIZE => 50;
use constant PAGE_URL => 'https://%s.wikipedia.org/wiki/%s';
# https://www.mediawiki.org/wiki/API:Search
use constant SEARCH_URL => 'https://%s.wikipedia.org/w/api.php?format=json&action=query&list=search&srsearch=%s&srprop=snippet|categorysnippet'; # params: language, query string
# https://www.mediawiki.org/wiki/API:Get_the_contents_of_a_page#Method_3:_Use_the_TextExtracts_API
use constant FETCH_URL => 'https://%s.wikipedia.org/w/api.php?action=query&prop=extracts&formatversion=2&format=json&pageids=%s'; # params: language, page ID

my $log = logger('plugin.musicartistinfo');
my $prefs = preferences('plugin.musicartistinfo');

sub _rank {
	my $item = shift;
	my ($condition, $value, $message);

	my $condition = shift if scalar @_ == 3;
	my ($value, $message) = @_;

	if ($condition) {
		main::INFOLOG && $log->is_info && $log->info($message);
		$item->{ranking} += $value;
	}

	return $condition;
}

sub getAlbumReview {
	my ( $class, $client, $cb, $args ) = @_;
	my $lang = $args->{lang} || _language($client);

	Plugins::MusicArtistInfo::Common->call(
		sprintf(SEARCH_URL, $lang, uri_escape_utf8('"' . $args->{album} . '" album "' . $args->{artist} . '"')),
		sub {
			my $searchResults = shift;

			my $candidates = eval('$searchResults->{query}->{search}') || [];

			$log->warn($@) if $@;

			my ($candidate) = sort {
				$b->{ranking} <=> $a->{ranking}
			} grep {
				$_->{ranking} > 5;
			} map {
				$_->{snippet} = _removeMarkup($_->{snippet});
				$_->{categorysnippet} = _removeMarkup($_->{categorysnippet});

				my $title = lc($_->{title});
				$title =~ s/\s*\(.*album\)//ig;

				$_->{ranking} = 0;

				if (_rank($_, $title eq lc($args->{album}), 10, 'exact title match')) {}
				elsif (_rank($_, ($title =~ /^\Q$args->{album}\E/i || $args->{album} =~ /^\Q$title\E/i), 7, 'partial title match')) {}
				elsif (_rank($_, Text::Levenshtein::distance($title, lc($args->{album})) < 10, 5, 'levenshtein 10')) {}

				if (_rank($_, lc($_->{snippet}) eq lc($args->{artist}), 5, 'artist match')) {}
				elsif (_rank($_, $_->{snippet} =~ /^\Q$args->{artist}\E/i, 3, 'snippet starts with artist')) {}
				elsif (_rank($_, $_->{snippet} =~ /\Q$args->{artist}\E/i, 2, 'snippet has artist')) {}

				_rank($_, $_->{snippet} =~ /\Q$args->{album}\E/i && $_->{title} =~ /album/i, 1, 'snippet has album');
				_rank($_, $title eq lc($args->{album}) && length($args->{album}) > 20, 5, 'matches a long album title');

				main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump($_));

				$_;
			} @$candidates;

			main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump($candidate ? $candidate : $candidates));

			$candidate ||= {};

			if (!$candidate->{pageid} && $lang ne 'en' && $prefs->get('fallBackToEnglish')) {
				$args->{lang} = 'en';
				return $class->getAlbumReview($client, $cb, $args);
			}

			$class->getPage($client, sub {
				my $review = shift;

				$review->{review} = delete $review->{content};
				$review->{reviewText} = delete $review->{contentText};

				$cb->($review);
			}, {
				title => $candidate->{title},
				id => $candidate->{pageid},
				lang => $args->{lang},
			});
		},{
			cache => 1,
			expires => 86400,	# force caching - wikipedia doesn't want to cache by default
		}
	);
}

sub getBiography {
	my ( $class, $client, $cb, $args ) = @_;

	Plugins::MusicArtistInfo::Common->call(
		sprintf(SEARCH_URL, $args->{lang} || _language($client), uri_escape_utf8($args->{artist})),
		sub {
			my $searchResults = shift;

			my $candidates = eval('$searchResults->{query}->{search}') || [];

			$log->warn($@) if $@;

			my ($candidate) = grep {
				$_->{title} =~ /^\Q$args->{artist}\E/i
					|| Text::Levenshtein::distance(lc($_->{title}), lc($args->{artist})) < 10;
			} map {
				$_->{snippet} = _removeMarkup($_->{snippet});
				$_->{categorysnippet} = _removeMarkup($_->{categorysnippet});
				$_;
			} @$candidates;

			main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump($candidate ? $candidate : $candidates));

			$candidate ||= {};

			if (!$candidate->{pageid} && !$args->{lang} && _language($client) ne 'en' && $prefs->get('fallBackToEnglish')) {
				$args->{lang} = 'en';
				return $class->getAlbumReview($client, $cb, $args);
			}

			$class->getPage($client, sub {
				my $bio = shift;

				$bio->{bio} = delete $bio->{content};
				$bio->{bioText} = delete $bio->{contentText};

				$cb->($bio);
			}, {
				title => $candidate->{title},
				id => $candidate->{pageid},
				lang => $args->{lang},
			});
		},{
			cache => 1,
			expires => 86400,	# force caching - wikipedia doesn't want to cache by default
		}
	);
}

sub _removeMarkup {
	HTML::FormatText->format_string(
		$_[0],
		leftmargin => 0,
	);
}

sub getPage {
	my ( $class, $client, $cb, $args ) = @_;

	if (!$args->{id}) {
		return $cb->({
			error => cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND')
		});
	}

	Plugins::MusicArtistInfo::Common->call(
		sprintf(FETCH_URL, $args->{lang} || _language($client), uri_escape_utf8($args->{id})),
		sub {
			my $fetchResults = shift;

			my $result = {};

			if ( $fetchResults && ref $fetchResults && $fetchResults->{query} && (my $content = $fetchResults->{query}->{pages}) ) {
				if (length($content->[0]->{extract}) > MIN_REVIEW_SIZE) {
					$result->{content} = $content->[0]->{extract};
					$result->{content} =~ s/\n//g;
					$result->{content} = '<link rel="stylesheet" type="text/css" href="/plugins/MusicArtistInfo/html/wikipedia.css" />' . $result->{content};

					$result->{contentText} = _removeMarkup($result->{content});

					my $slug = $args->{title};
					$slug =~ s/ /_/g;
					$result->{content} .= sprintf('<p><br><a href="%s" target="_blank">%s</a></p>',
						sprintf(PAGE_URL, $args->{lang} || _language($client), uri_escape_utf8($slug)),
						cstring($client, 'PLUGIN_MUSICARTISTINFO_READ_MORE')
					);
				}
			}

			if ( !$result->{content} && !main::SCANNER ) {
				$result->{error} ||= cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND');
			}

			$cb->($result);
		},{
			cache => 1,
			expires => 86400,	# force caching - wikipedia doesn't want to cache by default
		}
	);
}

sub _language {
	my $client = shift;
	return cstring($client, 'PLUGIN_MUSICARTISTINFO_WIKIPEDIA_LANGUAGE');
}

1;