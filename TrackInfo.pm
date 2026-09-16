package Plugins::MusicArtistInfo::TrackInfo;

use strict;

use Async::Util;
use File::Basename qw(dirname);
use File::Slurp qw(read_file write_file);
use File::Spec::Functions qw(catfile catdir);

use Slim::Menu::TrackInfo;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;

use Plugins::MusicArtistInfo::API;
use Plugins::MusicArtistInfo::Common qw(CLICOMMAND isDirWritable);
use Plugins::MusicArtistInfo::Parser::LRC;

my $log = logger('plugin.musicartistinfo');
my $onlineLog = logger('plugin.musicartistinfo.online');
my $prefs = preferences('plugin.musicartistinfo');

my $lyricsProviderPipeline = [
	'MAILyricsAPI',
	# 'AZLyrics',
	# 'LRCLibGet',
	# 'LRCLibSearch',
	# 'ChartLyrics',
	'Genius',
	'GeniusNoDot',
];

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

	Slim::Utils::Timers::setTimer(__PACKAGE__, time() + rand(5), \&updateLyricsProviders);
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
	my $album  = $request->getParam('album');
	my $title  = $request->getParam('title');
	my $id     = $request->getParam('track_id');
	my $url    = $request->getParam('url');
	my $duration = $request->getParam('duration');

	my $args   = {
		artist => $artist,
		album  => $album,
		title  => $title,
		url    => $url,
		track_id => $id,
		duration => $duration
	};

	if (defined $id){
		$args->{track} = Slim::Schema->find('Track', $id);
	}
	elsif ($url) {
		$args->{track} = Slim::Schema->objectForUrl($url);
	}
	elsif ($client) {
		$args->{track} = Plugins::MusicArtistInfo::Common::getTrackAndRadioUrl($client, $args);
	}

	if ($args->{track}) {
		$args->{artist} //= $args->{track}->artistName;
		$args->{album}  //= $args->{track}->albumname;
		$args->{title}  //= $args->{track}->title;
		$args->{duration} = $args->{track}->secs;
		$args->{radioUrl} //= $args->{track}->url if Slim::Music::Info::isHTTPURL($args->{track}->url);

		if ( $client && !($args->{track} && $args->{artist} && $args->{title} && $args->{duration} && $args->{album}) && $args->{track}->isRemoteURL ) {
			my $handler = Slim::Player::ProtocolHandlers->handlerForURL($args->{track}->url);

			if ( $handler && $handler->can('getMetadataFor') ) {
				my $meta = $handler->getMetadataFor( $client, $args->{track}->url );
				$args->{artist} //= $meta->{artist};
				$args->{album}  //= $meta->{album};
				$args->{title}  //= $meta->{title};
				$args->{duration} ||= $meta->{duration};
			}
		}
	}

	$args->{radioUrl} ||= $url if Slim::Music::Info::isHTTPURL($url);

	# remove album/duration from radio streams - they're most likely invalid data
	if ($args->{radioUrl}) {
		delete $args->{album};
		delete $args->{duration};
	}

	# some cleanup... music services add too many appendices
	$args->{title} =~ s/[([][^)\]]*?(deluxe|edition|remaster|live|anniversary)[^)\]]*?[)\]]//ig;
	$args->{title} =~ s/ -[^-]*(deluxe|edition|remaster|live|anniversary).*//ig;

	# specific rule for the "[E]"xplicit flag - it's too specific/short to fit in with the above
	$args->{title} =~ s/\[E\]//g;

	# remove trailing non-word characters
	$args->{title} =~ s/[\s\W]{2,}$//;
	$args->{title} =~ s/\s*$//;

	my $killWords = Plugins::MusicArtistInfo::Common::getKillWords() || {};
	foreach (qw(title artist album)) {
		delete $args->{$_} if $killWords->{lc($args->{$_} || '')};
	}

	# Radio Now Playing adds the station after the pipe sign
	$args->{album} =~ s/\|.*// if $args->{album};

	if (!defined $args->{title} || !defined $args->{artist}
		|| $args->{title} eq '' || $args->{artist} eq ''
		|| (length($args->{title}) > 50 && length($args->{artist}) > 50)
	) {
		main::INFOLOG && $log->is_info && $log->info("Don't look up lyrics, as we lack track title ('$args->{title}') or artist name ('$args->{artist}').");
		$request->addResult('error', cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND'));
		$request->setStatusDone();
		return;
	}

	main::INFOLOG && $log->is_info && $log->info("Getting lyrics for " . $args->{title} . ' by ' . $args->{artist});

	my $forceOnlineLookup = main::DEBUGLOG && $onlineLog->is_debug;
	if ( !$forceOnlineLookup && $args->{track} && (my $lyrics = $args->{track}->lyrics) ) {
		_renderLyricsResponse($lyrics, $request, $args);
		$request->setStatusDone();
		return;
	}

	if ( !$forceOnlineLookup && (my $lyrics = _getCachedLyrics($args) || _getLocalLyrics($args)) ) {
		main::INFOLOG && $log->is_info && $log->info("Found cached/local lyrics for " . $args->{title} . ' by ' . $args->{artist});
		_renderLyricsResponse($lyrics, $request, $args);
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

my $lyricsProvider = {
	MAILyricsAPI => sub {
		my ($args, $cb) = @_;
		Plugins::MusicArtistInfo::API->getLyrics($cb, $args);
	},
	# AZLyrics => sub {
	# 	require Plugins::MusicArtistInfo::Lyrics::AZLyrics;
	# 	Plugins::MusicArtistInfo::Lyrics::AZLyrics->getLyrics(@_);
	# },
	# no lookup, only tell LRCLib to use the proxy
	# LRCLibProxyEnable => sub {
	# 	my ($args, $scb) = @_;
	# 	require Plugins::MusicArtistInfo::Lyrics::LRCLib;
	# 	Plugins::MusicArtistInfo::Lyrics::LRCLib->enableProxying();
	# 	$scb->();
	# },
	# LRCLibGet => sub {
	# 	require Plugins::MusicArtistInfo::Lyrics::LRCLib;
	# 	Plugins::MusicArtistInfo::Lyrics::LRCLib->getLyrics(@_)
	# },
	# LRCLibSearch => sub {
	# 	require Plugins::MusicArtistInfo::Lyrics::LRCLib;
	# 	Plugins::MusicArtistInfo::Lyrics::LRCLib->searchLyrics(@_)
	# },
	# ChartLyrics => sub {
	# 	require Plugins::MusicArtistInfo::Lyrics::ChartLyrics;
	# 	Plugins::MusicArtistInfo::Lyrics::ChartLyrics->searchLyricsInDirect(@_);
	# },
	Genius => sub {
		require Plugins::MusicArtistInfo::Lyrics::Genius;
		Plugins::MusicArtistInfo::Lyrics::Genius->getLyrics(@_);
	},
	GeniusNoDot => sub {
		my ($args, $scb) = @_;

		if ($args->{title} !~ /\./ && $args->{artist} !~ /\./) {
			return $scb->();
		}
		else {
			require Plugins::MusicArtistInfo::Lyrics::Genius;
			# try one more time with punctuation removed - https://github.com/michaelherger/MusicArtistInfo/issues/12
			$args->{artist} =~ s/\.//g;
			$args->{title}  =~ s/\.//g;

			Plugins::MusicArtistInfo::Lyrics::Genius->getLyrics($args, $scb);
		}
	}
};

sub _fetchLyrics {
	my ($args, $cb, $ecb) = @_;

	my $lyricsResult;

	my $handlerPipeline = [
		grep { $_ }
		map { $lyricsProvider->{$_} }
		@{$prefs->get('lyricsProviders') || $lyricsProviderPipeline}
	];

	Async::Util::amap(
		inputs => $handlerPipeline,
		action => sub {
			my ($handler, $acb) = @_;

			if ($lyricsResult) {
				$acb->($lyricsResult);
				return;
			}

			$handler->($args, sub {
				my $result = shift;

				if ($result && ref $result && keys %$result && !$result->{error}) {
					$lyricsResult = $result;
					$acb->($result);
				}
				else {
					$acb->();
				}
			});
		},
		cb => sub {
			if ($lyricsResult && ref $lyricsResult && keys %$lyricsResult && !$lyricsResult->{error}) {
				$cb->($lyricsResult);
			}
			else {
				$ecb->($lyricsResult);
			}
		},
		at_a_time => 1,
	);
}

sub _cacheLyrics {
	my ($args, $lyrics) = @_;

	return unless $lyrics;

	if (my $lyricsFile = _getLyricsCacheFile($args, 'create')) {
		my $encodedLyrics = $lyrics;
		utf8::encode($encodedLyrics);

		$lyricsFile =~ s/\.txt$/.lrc/ if $encodedLyrics =~ /^\[\d+:\d+\.\d+\]/gm;

		write_file($lyricsFile, { err_mode => 'carp' }, $encodedLyrics) || $log->error("Failed to write lyrics to $lyricsFile");
	}
}

sub _getCachedLyrics {
	my ($args) = @_;

	if (my $lyricsFile = _getLyricsCacheFile($args)) {
		$lyricsFile =~ s/\.txt$/.lrc/ if !-f $lyricsFile;

		main::INFOLOG && $log->is_info && $log->info("Trying to get lyrics from $lyricsFile");

		if (-f $lyricsFile) {
			main::INFOLOG && $log->is_info && $log->info("Found cached lyrics!");
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

		if (!$create || isDirWritable($lyricsFolder)) {
			my $artistDir = catdir($lyricsFolder, @{Plugins::MusicArtistInfo::Common::getLocalnameVariants($args->{artist})}[0]);
			$artistDir =~ s/\.$//;
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
	my $url = $track->url if $track;
	$url ||= $args->{url};
	$url =~ s/^tmp:/file:/ if $url;

	my $lyrics;

	# try "Song.mp3.lrc" and "Song.lrc"
	if ($url && Slim::Music::Info::isFileURL($url)) {
		my $filePath = Slim::Utils::Misc::pathFromFileURL($url);
		my $filePath2 = $filePath . '.lrc';
		$filePath =~ s/\.\w{2,4}$/.lrc/;

		# try .lrc files first
		my @files = ($filePath, $filePath2);

		# text files second
		$filePath =~ s/\.lrc$/.txt/;
		$filePath2 =~ s/\.lrc$/.txt/;

		push @files, $filePath, $filePath2;

		foreach my $file (@files) {
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

sub _renderLyricsResponse {
	my ($lyrics, $request, $args) = @_;

	my $client = $request->client();

	$lyrics =~ s/\\n/\n/g;
	$lyrics =~ s/\r\n/\n/g;
	$lyrics =~ s/\n\r/\n/g;
	$lyrics =~ s/\r/\n/g;

	$lyrics = Plugins::MusicArtistInfo::Parser::LRC->strip($lyrics, $request->getParam('timestamps') && !$args->{radioUrl});

	$request->addResult('lyrics', $lyrics) if $lyrics;
	$request->addResult('error', cstring($client, 'PLUGIN_MUSICARTISTINFO_NOT_FOUND')) unless $lyrics;
	$request->addResult('title', $args->{title}) if $args->{title};
	$request->addResult('artist', $args->{artist}) if $args->{artist};
}

sub updateLyricsProviders {
	my ($class) = @_;

	Slim::Utils::Timers::killTimers($class, \&updateLyricsProviders);

	Plugins::MusicArtistInfo::API->getLyricsProviders(sub {
		my $result = shift;

		if ($result && ref $result && ref $result eq 'HASH' && $result->{lyricsProviders} && ref $result->{lyricsProviders} eq 'ARRAY') {
			my @lyricsProviders = Slim::Utils::Misc::uniq(grep {
				$lyricsProvider->{$_};
			} @{$result->{lyricsProviders}});

			$prefs->set('lyricsProviders', \@lyricsProviders) if @lyricsProviders;
		}

		Slim::Utils::Timers::setTimer($class, time() + 23*3600 + rand(3600), \&updateLyricsProviders);
	});
}


1;