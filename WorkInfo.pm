package Plugins::MusicArtistInfo::WorkInfo;

use strict;

use Slim::Utils::Log;
use Slim::Utils::Strings qw(string cstring);

use Plugins::MusicArtistInfo::Common qw(CLICOMMAND);

my $log = logger('plugin.musicartistinfo');

sub init {
	my ($class) = @_;

#                                                                |requires Client
#                                                                |  |is a Query
#                                                                |  |  |has Tags
#                                                                |  |  |  |Function to call
#                                                                C  Q  T  F
	Slim::Control::Request::addDispatch([CLICOMMAND, 'workreview'],
	                                                            [0, 1, 1, \&getWorkReviewCLI]);
}

sub getWorkReviewCLI {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([[CLICOMMAND], ['workreview']])) {
		$request->setStatusBadDispatch();
		return;
	}

	$request->setStatusProcessing();

	my $client = $request->client();

	my $args;
	my $workId = $request->getParam('work_id');
	my $title  = $request->getParam('work');
	my $composer = $request->getParam('composer');
	my $lang   = $request->getParam('lang');
	my $mbid   = $request->getParam('mbid');

	my $args = _getWorkFromWorkId($workId)
		|| {
			title    => $title,
			composer => $composer,
		};

	if ( !($args && $args->{title} && $args->{composer}) ) {
		$request->addResult('error', cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND'));
		$request->setStatusDone();
		return;
	}

	$args->{lang} = $lang if $lang;

	getWorkReview($client, sub {
		my $review = shift;

		# if we got an error back, convert it to a user-friendly message.
		if ($review && ref $review eq 'HASH' && $review->{error}) {
			$review = { error => cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND') };
		}

		$request->addResult('review', $review);
		$request->setStatusDone();
	},{
		isWeb  => $request->getParam('html') || Plugins::MusicArtistInfo::Plugin->isWebBrowser($client),
	}, $args);
}

sub _getWorkFromWorkId {
	my $workId = shift;

	if ($workId) {
		my $work = Slim::Schema->resultset("Work")->find($workId);

		if ($work) {
			main::INFOLOG && $log->is_info && $log->info('Got Work from work ID: ' . $work->title . ' - ' . $work->composer->name);

			return {
				composer => $work->composer->name,
				title    => $work->title,
				work_id  => $work->id,
			};
		}
	}
}

sub getWorkReview {
	my ($client, $cb, $params, $args) = @_;

	# if ( my $review = Plugins::MusicArtistInfo::LocalFile->getWorkReview($client, $params, $args) ) {
	# 	$cb->($review);
	# 	return;
	# }

	$args->{lang} ||= cstring($client, 'PLUGIN_MUSICARTISTINFO_LASTFM_LANGUAGE');

	Plugins::MusicArtistInfo::API->getWorkReviewId(
		sub {
			my $reviewData = shift;

			# TODO - respect fallback language setting?
			if ($reviewData && (my $pageData = $reviewData->{wikidata})) {
				Plugins::MusicArtistInfo::Wikipedia->getPage($client, sub {
					my $review = shift;

					if ($review && $review->{content} && $review->{contentText}) {
						my $items = [];

						$reviewData->{url} ||= $review->{url} || {};

						if ($review->{error}) {
							if (keys %$reviewData && Plugins::MusicArtistInfo::Plugin->isWebBrowser($client, $params)) {
								$review->{error} = sprintf("<p>%s</p>\n%s", $review->{error}, Plugins::MusicArtistInfo::Common::getExternalLinks($client, $reviewData));
							}

							$items = [{
								name => $review->{error},
								type => 'text'
							}]
						}
						elsif ($review->{content}) {
							my $content = '';
							if ( Plugins::MusicArtistInfo::Plugin->isWebBrowser($client, $params) ) {
								$content = '<h4>' . $review->{author} . '</h4>' if $review->{author};
								$content .= '<div><img src="' . $review->{image} . '" onerror="this.style.display=\'none\'"></div>' if $review->{image};
								$content .= $review->{content};
								$content .= Plugins::MusicArtistInfo::Common::getExternalLinks($client, $reviewData);
							}
							else {
								$content = $review->{author} . '\n\n' if $review->{author};
								$content .= $review->{contentText};
							}

							$items = Plugins::MusicArtistInfo::Plugin->textAreaItem($client, $params->{isButton}, $content);
						}

						$cb->($items);

						return;
					}

					$cb->([]);
				}, {
					title => $pageData->{title},
					id => $pageData->{pageid},
					lang => $pageData->{lang} || $args->{lang},
				});

				return;
			}

			$cb->([]);
		},
		$args,
	);
}

1;