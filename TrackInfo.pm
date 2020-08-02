package Plugins::MusicArtistInfo::TrackInfo;

use strict;

use File::Basename qw(dirname);
use File::Slurp qw(read_file write_file);
use File::Spec::Functions qw(catfile catdir);

use Slim::Menu::TrackInfo;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;

use Plugins::MusicArtistInfo::Lyrics::ChartLyrics;

use Plugins::MusicArtistInfo::Parser::LRC;

use constant CLICOMMAND => 'musicartistinfo';

my $log = logger('plugin.musicartistinfo');
my $prefs = preferences('plugin.musicartistinfo');

sub init {
#                                                                |requires Client
#                                                                |  |is a Query
#                                                                |  |  |has Tags
#                                                                |  |  |  |Function to call
#                                                                C  Q  T  F
	Slim::Control::Request::addDispatch([CLICOMMAND, 'lyrics'], [0, 1, 1, \&getSongLyricsCLI]);

	Slim::Menu::TrackInfo->registerInfoProvider( moretrackinfo => (
		func => \&_objInfoHandler,
		after => 'moreartistinfo',
	) );
}

sub _objInfoHandler {
	my ( $client, $url, $obj, $remoteMeta ) = @_;

	my ($title, $artist, $id);

	if ( $obj && blessed $obj ) {
		if ($obj->isa('Slim::Schema::Track')) {
			$id     = $obj->id;
			$title  = $obj->title;
			$artist = $obj->artistName;
		}

		# no need to render our "Lyrics" item if track has lyrics - it'll be added by default handler anyway.
		return if $obj->lyrics;
	}

	$remoteMeta ||= {};
	$title ||= $remoteMeta->{title};
	$artist ||= $remoteMeta->{artist};

	if ( !($title && $artist) && $obj->remote ) {
		my $request = Slim::Control::Request::executeRequest($client, ['status', 0, 10]);
		my $remoteMeta = $request->getResult('remoteMeta');

		$title ||= $remoteMeta->{title};
		$artist ||= $remoteMeta->{artist};
	}

	return unless $id || ($title && $artist);

	return {
		name => cstring($client, 'LYRICS'),
		type => 'link',
		url => \&getLyrics,
		passthrough => [ {
			id     => $id,
			title  => $title,
			artist => $artist,
			url    => $url,
		} ],
	};
}

sub getSongLyricsCLI {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([[CLICOMMAND], ['lyrics']])) {
		$request->setStatusBadDispatch();
		return;
	}

	$request->setStatusProcessing();

	my $client = $request->client();

	my $args;
	my $artist = $request->getParam('artist');
	my $title  = $request->getParam('title');
	my $id     = $request->getParam('track_id');
	my $url    = $request->getParam('url');

	my $args   = {
		artist => $artist,
		title  => $title,
		url    => $url,
		track_id => $id
	};

	if ($id || $url) {
		if (defined $id){
			$args->{track} = Slim::Schema->find('Track', $id);
		}
		elsif ($url) {
			$args->{track} = Slim::Schema->objectForUrl($url);
		}

		if ($args->{track}) {
			$args->{artist} ||= $args->{track}->artistName;
			$args->{title}  ||= $args->{track}->title;
		}
	}

	main::INFOLOG && $log->is_info && $log->info("Getting lyrics for " . $args->{title} . ' by ' . $args->{artist});

	if (my $lyrics = _getCachedLyrics($args) || _getLocalLyrics($args)) {
		_renderLyricsResponse($lyrics, $request, $args);
		$request->setStatusDone();
		return;
	}

	if ( !($args && $args->{artist} && $args->{title}) ) {
		$request->addResult('error', cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND'));
		$request->setStatusDone();
		return;
	}

	_fetchLyrics($args, sub {
		my $item = shift;

		my $lyrics = $item->{lyrics};

		# CLI clients expect real line breaks, not literal \n
		_renderLyricsResponse($lyrics, $request, $args);

		_cacheLyrics($args, $lyrics);

		$request->setStatusDone();
	}, sub {
		my $item = shift;
		if ( !$item || !ref $item ) {
			$request->addResult('error', cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND'));
		}
		elsif ( $item->{error} ) {
			$request->addResult('error', $item->{error});
		}

		$request->setStatusDone();
	})
}

sub getLyrics {
	my ($client, $cb, $params, $args) = @_;

	$params ||= {};
	$args   ||= {};
	$cb     ||= sub {};

	my $gotLyrics = sub {
		my $lyricsRequest = shift;

		my $responseText = $lyricsRequest->getResult('lyrics') || $lyricsRequest->getResult('error');

		$cb->({
			items => Plugins::MusicArtistInfo::Plugin->textAreaItem($client, $params->{isButton}, $responseText),
		});
	};

	my $command = [CLICOMMAND, 'lyrics'];
	foreach (qw(title artist url track_id)) {
		my $v = $args->{$_};
		if (defined $v && $v ne '') {
			push @$command, "$_:$v";
		}
	}

	my $request = Slim::Control::Request::executeRequest($client, $command);
	if ( $request->isStatusProcessing ) {
		$request->callbackFunction($gotLyrics);
	} else {
		$gotLyrics->($request);
	}
}

sub _fetchLyrics {
	my ($args, $cb, $ecb) = @_;

	# some cleanup... music services add too many appendices
	$args->{title} =~ s/[([][^)]].?(deluxe|edition|remaster|live|anniversary)[^)]].?[)]]//ig;
	$args->{title} =~ s/ -[^-]*(deluxe|edition|remaster|live|anniversary).*//ig;

	# remove trailing non-word characters
	$args->{title} =~ s/[\s\W]{2,}$//;
	$args->{title} =~ s/\s*$//;

	Plugins::MusicArtistInfo::Lyrics::ChartLyrics->searchLyricsInDirect($args, sub {
		my $results = shift;

		if ($results && keys %$results && !$results->{error}) {
			$cb->($results);
		}
		else {
			main::INFOLOG && $log->is_info && $log->info('Failed lookup on ChartLyrics - falling back to AZLyrics');
			require Plugins::MusicArtistInfo::Lyrics::AZLyrics;

			Plugins::MusicArtistInfo::Lyrics::AZLyrics->getLyrics($args, sub {
				$results = shift;

				if ($results && keys %$results && !$results->{error}) {
					$cb->($results);
				}
				else {
					main::INFOLOG && $log->is_info && $log->info('Failed lookup on AZLyrics - falling back to Genius');
					require Plugins::MusicArtistInfo::Lyrics::Genius;

					Plugins::MusicArtistInfo::Lyrics::Genius->getLyrics($args, sub {
						$results = shift;

						if ($results && keys %$results && !$results->{error}) {
							$cb->($results);
						}
						else {
							$ecb->($results);
						}
					});
				}
			});
		}
	});
}

sub _cacheLyrics {
	my ($args, $lyrics) = @_;

	return unless $lyrics;

	if (my $lyricsFile = _getLyricsCacheFile($args, 'create')) {
		my $encodedLyrics = $lyrics;
		utf8::encode($encodedLyrics);

		write_file($lyricsFile, { err_mode => 'carp' }, $encodedLyrics) || $log->error("Failed to write lyrics to $lyricsFile");
	}
}

sub _getCachedLyrics {
	my ($args) = @_;

	if (my $lyricsFile = _getLyricsCacheFile($args)) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Trying to get lyrics from $lyricsFile");

		if (-f $lyricsFile) {
			my $lyrics = read_file($lyricsFile);
			utf8::decode($lyrics);
			return $lyrics;
		}
	}

	return;
}

sub _getLyricsCacheFile {
	my ($args, $create) = @_;

	if ( $args->{title} && $args->{artist} && (my $lyricsFolder = $prefs->get('lyricsFolder')) ) {
		mkdir $lyricsFolder if $create && ! -d $lyricsFolder;

		if (-w $lyricsFolder) {
			my $artistDir = catdir($lyricsFolder, @{Plugins::MusicArtistInfo::Common::getLocalnameVariants($args->{artist})}[0]);
			mkdir $artistDir if $create && ! -d $artistDir;

			my $candidates = Plugins::MusicArtistInfo::Common::getLocalnameVariants($args->{title});
			my $lyricsFile = catfile($artistDir, $candidates->[0] . '.txt');

			return $lyricsFile;
		}
	}

	return;
}

sub _getLocalLyrics {
	my ($args) = @_;

	my $track = $args->{track};
	my $url;

	if ($track) {
		if (my $lyrics = $track->lyrics) {
			return $lyrics;
		}

		$args->{title} ||= $track->title;
		$args->{artist} ||= $track->artistName;
		$url = $track->url;
	}

	$url ||= $args->{url};
	$url =~ s/^tmp:/file:/ if $url;

	my $lyrics;

	# try "Song.mp3.lrc" and "Song.lrc"
	if ($url && Slim::Music::Info::isFileURL($url)) {
		my $filePath = Slim::Utils::Misc::pathFromFileURL($url);
		my $filePath2 = $filePath . '.lrc';
		$filePath =~ s/\.\w{2,4}$/.lrc/;

		# try .lrc files first
		$lyrics = Plugins::MusicArtistInfo::Parser::LRC->parse($filePath)
		    || Plugins::MusicArtistInfo::Parser::LRC->parse($filePath2);

		return $lyrics if $lyrics;

		# text files second
		$filePath =~ s/\.lrc$/.txt/;
		$filePath2 =~ s/\.lrc$/.txt/;

		foreach my $file ($filePath, $filePath2) {
			if (-r $file) {
				$lyrics = File::Slurp::read_file($file);
				if ($lyrics) {
					utf8::decode($lyrics);
					last;
				}
			}
		}

		return $lyrics if $lyrics;
	}

	if ($args->{artist} && $args->{title}) {
		my $lyricsCacheFolder = _getLyricsCacheFile({
			artist => $args->{artist},
			title => $args->{title}
		});
		$lyricsCacheFolder = dirname($lyricsCacheFolder) if $lyricsCacheFolder;

		if ($lyricsCacheFolder && -r $lyricsCacheFolder) {
			my $candidates = Plugins::MusicArtistInfo::Common::getLocalnameVariants($args->{title});

			opendir(LYRICSDIR, $lyricsCacheFolder) && do {
				my %files = map {
					s/\.txt$//;
					lc($_) => "$_.txt";
				} grep {
					$_ !~ /^(?:\.\.|\.)$/;
				} readdir(LYRICSDIR);
				closedir(LYRICSDIR);

				if (keys %files) {
					foreach (@$candidates) {
						if ( my $file = $files{lc($_)} ) {

							$lyrics = File::Slurp::read_file(catfile($lyricsCacheFolder, $file));
							if ($lyrics) {
								utf8::decode($lyrics);
								last;
							}
						}
					}
				}
			};
		}
	}

	return $lyrics;
}

sub _renderLyrics {
	my ($item, $args) = @_;
	$item ||= {};
	$args ||= {};

	my $title  = $args->{title} || $item->{song};
	my $artist = $args->{artist} || $item->{artist};

	my $lyrics = $title if $title;
	$lyrics .= ' - ' if $lyrics && $artist;
	$lyrics .= $artist if $artist;
	$lyrics .= "\n\n" if $lyrics;
	$lyrics .= $item->{lyrics} if $item->{lyrics};

	return $lyrics;
}

sub _renderLyricsResponse {
	my ($lyrics, $request, $args) = @_;

	my $client = $request->client();

	$lyrics =~ s/\\n/\n/g;
	$lyrics =~ s/\r\n/\n/g;
	$lyrics =~ s/\n\r/\n/g;

	$request->addResult('lyrics', $lyrics) if $lyrics;
	$request->addResult('error', cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND')) unless $lyrics;
	$request->addResult('title', $args->{title}) if $args->{title};
	$request->addResult('artist', $args->{artist}) if $args->{artist};
}

1;