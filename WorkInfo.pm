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

	my $args = _getWorkFromWorkId($workId) || {
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
		Plugins::MusicArtistInfo::AlbumInfo::renderReviewCLIResponse($request, shift, sub {
			my ($request, $item) = @_;
			$request->addResult('workreview', $item->{name});
			$request->addResult('work_id', $args->{work_id}) if $args->{work_id};
			$request->addResult('work', $args->{title}) if $args->{title};
			$request->addResult('composer', $args->{composer}) if $args->{composer};
		});
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

	$args->{lang} ||= cstring($client, 'PLUGIN_MUSICARTISTINFO_WIKIPEDIA_LANGUAGE');
	$args->{artist} = $args->{composer};

	Plugins::MusicArtistInfo::API->getWorkReviewId(
		sub {
			Plugins::MusicArtistInfo::AlbumInfo::renderReview($client, 'work', shift, $params, $args, $cb);
		},
		$args,
	);
}

1;