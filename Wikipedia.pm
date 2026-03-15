package Plugins::MusicArtistInfo::Wikipedia;

use strict;

use HTML::FormatText;
use Text::Levenshtein;
use URI::Escape qw(uri_escape_utf8);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);

use Plugins::MusicArtistInfo::Common qw(CAN_IMAGEPROXY validateLanguage);

use constant MIN_REVIEW_SIZE => 50;
use constant PAGE_URL => 'https://%s.wikipedia.org/wiki/%s';
# https://www.mediawiki.org/wiki/API:Search
use constant SEARCH_URL => 'https://%s.wikipedia.org/w/api.php?format=json&action=query&list=search&srsearch=%s&srprop=snippet|categorysnippet'; # params: language, query string
# https://www.mediawiki.org/wiki/API:Get_the_contents_of_a_page#Method_3:_Use_the_TextExtracts_API
use constant FETCH_URL => 'https://%s.wikipedia.org/w/api.php?action=query&prop=extracts&formatversion=2&format=json&pageids=%s&redirects=1'; # params: language, page ID

# we need to localize search terms, but can't read from strings table, as we'd only have the main language, not what might have been requested
my $searchTypes = {
	album => {
		EN	=> 'Album',
		ES	=> 'Álbum',
		FI	=> 'Levy',
		PT	=> 'Álbum',
		ZH_CN	=> '专辑'
	},
	work => {
		CS	=> 'Díla',
		DA	=> 'Værk',
		DE	=> 'Werk',
		EN	=> 'work',
		ES	=> 'Obra',
		FR	=> 'Œuvre',
		HU	=> 'Művek',
		NL	=> 'Compositie',
		PT	=> 'Obra',
		SV	=> 'Verk',
		ZH_CN	=> '作品'
	},
};

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

sub getAlbumOrWorkReview {
	my ( $class, $client, $cb, $type, $args ) = @_;
	my $lang = validateLanguage($client, $args->{lang});

	# need to localize "$type" - see https://forums.lyrion.org/node/1813577
	my $localizedType = $searchTypes->{$type}->{uc($lang)} || $searchTypes->{$type}->{EN} || $type;

	Plugins::MusicArtistInfo::Common->call(
		sprintf(SEARCH_URL, $lang, uri_escape_utf8('"' . $args->{title} . '" ' . $localizedType . ' "' . $args->{artist} . '"')),
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
				$title =~ s/\s*\(.*(?:$type|$localizedType)\)//ig;

				$_->{ranking} = 0;

				if (_rank($_, $title eq lc($args->{title}), 10, 'exact title match')) {}
				elsif (_rank($_, ($title =~ /^\Q$args->{title}\E/i || $args->{title} =~ /^\Q$title\E/i), 7, 'partial title match')) {}
				elsif (_rank($_, Text::Levenshtein::distance($title, lc($args->{title})) < 10, 5, 'levenshtein 10')) {}

				if (_rank($_, lc($_->{snippet}) eq lc($args->{artist}), 5, 'artist match')) {}
				elsif (_rank($_, $_->{snippet} =~ /^\Q$args->{artist}\E/i, 3, 'snippet starts with artist')) {}
				elsif (_rank($_, $_->{snippet} =~ /\Q$args->{artist}\E/i, 2, 'snippet has artist')) {}

				_rank($_, $_->{snippet} =~ /\Q$args->{title}\E/i && $_->{title} =~ /$type|$localizedType/i, 1, "snippet has $type");
				_rank($_, $title eq lc($args->{title}) && length($args->{title}) > 20, 5, "matches a long $type title");

				main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump($_));

				$_;
			} @$candidates;

			main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump($candidate ? $candidate : $candidates));

			$candidate ||= {};

			if (!$candidate->{pageid} && $lang ne 'en') {
				$args->{lang} = 'en';
				return $class->getAlbumOrWorkReview($client, $cb, $type, $args);
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
		sprintf(SEARCH_URL, validateLanguage($client, $args->{lang}), uri_escape_utf8($args->{artist})),
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

			if (!$candidate->{pageid} && validateLanguage($client, $args->{lang}) ne 'en') {
				$args->{lang} = 'en';
				return $class->getBiography($client, $cb, $args);
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
		sprintf(FETCH_URL, validateLanguage($client, $args->{lang}), uri_escape_utf8($args->{id})),
		sub {
			my $fetchResults = shift;

			my $result = {};

			if ( $fetchResults && ref $fetchResults && $fetchResults->{query} && (my $content = $fetchResults->{query}->{pages}) ) {
				if (length($content->[0]->{extract}) > MIN_REVIEW_SIZE) {
					$result->{content} = $content->[0]->{extract};

					# sometimes we'd receive partial content which had been stripped out by the wikipedia API - let's remove from there on
					my $deadEndFound;
					$result->{content} = join('', grep {
						$deadEndFound ||= $_ =~ /data-mw-anchor=\\?"(?:Track_listing|Notes|Scores|Locations|Technical|Charts|References|Discography|Filmography|See_also|Explanatory_footnotes|Further_reading|Accolades|Einzelnachweise|Musikbeispiele|Auszeichnungen|Diskografie|Werbetestimonial|Filmmusik)/i;
						!$deadEndFound;
					} split(/\n/, $result->{content}));

					$result->{contentText} = _removeMarkup($result->{content});
					$result->{content} = '<link rel="stylesheet" type="text/css" href="/plugins/MusicArtistInfo/html/mai.css" />'
						. $result->{content}
						. '<div>(' . cstring($client, 'SOURCE') . cstring($client, 'COLON') . ' Wikipedia)</div>';

					my $slug = $args->{title};
					$slug =~ s/ /_/g;
					$result->{url} = sprintf(PAGE_URL, validateLanguage($client, $args->{lang}), uri_escape_utf8($slug));
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

1;