package Plugins::MusicArtistInfo::Wikipedia;

use strict;

use HTML::FormatText;
use Text::Levenshtein;
use URI::Escape qw(uri_escape_utf8);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string cstring);

use Plugins::MusicArtistInfo::Common qw(CAN_IMAGEPROXY);

use constant MIN_REVIEW_SIZE => 50;
use constant PAGE_URL => 'https://%s.wikipedia.org/wiki/%s';
# https://www.mediawiki.org/wiki/API:Search
use constant SEARCH_URL => 'https://%s.wikipedia.org/w/api.php?format=json&action=query&list=search&srsearch=%s&srprop=snippet';                 # params: language, query string
# https://www.mediawiki.org/wiki/API:Get_the_contents_of_a_page#Method_3:_Use_the_TextExtracts_API
use constant FETCH_URL => 'https://%s.wikipedia.org/w/api.php?action=query&prop=extracts&exsentences=10&formatversion=2&format=json&pageids=%s'; # params: language, page ID

my $log = logger('plugin.musicartistinfo');

sub _albumSort {
	my ($a, $b, $album, $artist) = @_;
	return -1 if $a->{title} =~ /^\Q$album\E .*album/i;
	return 1 if $b->{title} =~ /^\Q$album\E .*album/i;
	return -1 if $a->{title} =~ /^\Q$album\E .*\Q$artist\E/i;
	return 1 if $b->{title} =~ /^\Q$album\E .*\Q$artist\E/i;
	return -1 if $a->{title} =~ /^\Q$album\E$/i;
	return 1 if $b->{title} =~ /^\Q$album\E$/i;
	return $a->{title} cmp $b->{title};
}

sub getAlbumReview {
	my ( $class, $client, $cb, $args ) = @_;

	Plugins::MusicArtistInfo::Common->call(
		sprintf(SEARCH_URL, _language($client), uri_escape_utf8($args->{album} . ' album ' . $args->{artist})),
		sub {
			my $searchResults = shift;

			my $candidates = eval('$searchResults->{query}->{search}') || [];

			$log->warn($@) if $@;

			my ($candidate) = sort {
				_albumSort($a, $b, $args->{album}, $args->{artist})
			} grep {
				($_->{title} =~ /^\Q$args->{album}\E/i || $args->{album} =~ /^\Q$_->{title}\E/i) || Text::Levenshtein::distance(lc($_->{title}), lc($args->{album})) < 10
					&& ($_->{snippet} =~ /\Q$args->{artist}\E/i
						|| $_->{snippet} =~ /\Q$args->{album}\E/i && $_->{title} =~ /album/i
						|| lc($_->{title}) eq lc($args->{album}) && length($args->{album}) > 20
					);
			} map {
				$_->{snippet} = HTML::FormatText->format_string(
					$_->{snippet},
					leftmargin => 0,
				);
				$_;
			} @$candidates;

			main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump($candidate ? $candidate : $candidates));

			$candidate ||= {};

			$class->getPage($client, $cb, {
				title => $candidate->{title},
				id => $candidate->{pageid},
			});
		},{
			cache => 1,
			expires => 86400,	# force caching - wikipedia doesn't want to cache by default
		}
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
		sprintf(FETCH_URL, _language($client), uri_escape_utf8($args->{id})),
		sub {
			my $fetchResults = shift;

			my $result = {};

			if ( $fetchResults && ref $fetchResults && $fetchResults->{query} && (my $review = $fetchResults->{query}->{pages}) ) {
				if (length($review->[0]->{extract}) > MIN_REVIEW_SIZE) {
					$result->{review} = $review->[0]->{extract};
					$result->{review} =~ s/\n//g;
					$result->{review} = '<link rel="stylesheet" type="text/css" href="/plugins/MusicArtistInfo/html/wikipedia.css" />' . $result->{review};

					$result->{reviewText} = HTML::FormatText->format_string(
						$result->{review},
						leftmargin => 0,
					);

					my $slug = $args->{title};
					$slug =~ s/ /_/g;
					$result->{review} .= sprintf('<p><br><a href="%s" target="_blank">%s</a></p>', sprintf(PAGE_URL, _language($client), uri_escape_utf8($slug)), cstring($client, 'PLUGIN_MUSICARTISTINFO_READ_MORE'));
				}
			}

			if ( !$result->{review} && !main::SCANNER ) {
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