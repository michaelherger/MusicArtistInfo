package Plugins::MusicArtistInfo::LocalFile;

use strict;
use File::Basename qw(dirname);
use File::Spec::Functions qw(catdir);
use Digest::MD5 qw(md5_hex);

use HTTP::Status qw(
    RC_FORBIDDEN
	RC_PRECONDITION_FAILED
	RC_UNAUTHORIZED
	RC_MOVED_PERMANENTLY
	RC_NOT_FOUND
	RC_METHOD_NOT_ALLOWED
	RC_OK
	RC_NOT_MODIFIED
);
use Path::Class ();

use Slim::Menu::AlbumInfo;
use Slim::Menu::FolderInfo;
use Slim::Menu::TrackInfo;

use Slim::Utils::Cache;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;

use Slim::Web::Pages;

use constant CLICOMMAND => 'musicartistinfo';

my $log   = logger('plugin.musicartistinfo');
my $prefs = preferences('plugin.musicartistinfo');
my $cache = Slim::Utils::Cache->new;

my $URL_PARSER_RE = qr{mai/localfile/([a-f\d]+)/(.*)$};

sub init { 
#                                                                    |requires Client
#                                                                    |  |is a Query
#                                                                    |  |  |has Tags
#                                                                    |  |  |  |Function to call
#                                                                    C  Q  T  F
	Slim::Control::Request::addDispatch([CLICOMMAND, 'localfiles'], [0, 1, 1, \&getLocalFileWeblinksCLI]);

	Slim::Menu::AlbumInfo->registerInfoProvider( morefileinfo => (
		func => \&albumInfoHandler,
		after => 'moreartwork',
	) );

	Slim::Menu::FolderInfo->registerInfoProvider( morefileinfo => (
		func => \&folderInfoHandler,
	) );

	Slim::Menu::TrackInfo->registerInfoProvider( morefileinfo => (
		func => \&trackInfoHandler,
		after => 'moreartwork',
	) );

	Slim::Web::Pages->addRawFunction(
		$URL_PARSER_RE,
		\&_proxyHandler,
	);
}

sub albumInfoHandler {
	my ( $client, $url, $album ) = @_;
	
	# try to grab the first album track to find it's folder location
	return trackInfoHandler($client, undef, $album->tracks->first);
}

sub folderInfoHandler {
	my ( $client, $tags ) = @_;

	return unless $tags->{folder_id};

	return trackInfoHandler($client, undef, Slim::Schema->find('Track', $tags->{folder_id}), undef, $tags);
}

sub trackInfoHandler {
	my ( $client, $url, $track, $remoteMeta, $tags ) = @_;

	return unless $client;
	
	# only deal with local media
	$url = $track->url if !$url && $track;
	return unless $url && $url =~ /^file:\/\//i;
	
	my $path = Slim::Utils::Misc::pathFromFileURL($url);
	
	if (! -d $path) {
		$path = dirname( $path );
	}

	my $files = _findTextFiles($path);

	return unless scalar @$files;
	
	# XMLBrowser for Jive can't handle weblinks - need custom handling there to show files in the browser.
	if ( Plugins::MusicArtistInfo::Plugin->canWeblink($client) )  {
		return {
			name => cstring($client, 'PLUGIN_MUSICARTISTINFO_LOCAL_FILES'),
			itemActions => {
				items => {
					command  => [ CLICOMMAND, 'localfiles' ],
					fixedParams => {
						folder => $path
					},
				},
			},
		}
	}
	
	my $items = [ map {	{
		type  => 'link',
		name  => $_->{file},
		weblink => _proxiedUrl($_->{path}, $_->{file}),
		url   => \&getFileContent,
		passthrough => [{
			path => catdir($_->{path}, $_->{file})
		}]
	} } @$files ];
	
	return {
		name => cstring($client, 'PLUGIN_MUSICARTISTINFO_LOCAL_FILES'),
		type => 'outline',
		items => $items,
	};	
}

sub getLocalFileWeblinksCLI {
	my $request = shift;
	
	my $client = $request->client;

	if ($request->isNotQuery([[CLICOMMAND], ['localfiles']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	$request->setStatusProcessing();

	my $path = $request->getParam('folder');
	my $files = _findTextFiles($path);

	my $i = 0;

	if (!scalar @$files) {
		$request->addResult('window', {
			textArea => cstring($client, 'EMPTY'),
		});
		$i++;
	}
	else {
		my $web_root = 'http://' . Slim::Utils::IPDetect::IP() . ':' . preferences('server')->get('httpport');
		
		foreach (@$files) {
			$request->addResultLoop('item_loop', $i, 'text', $_->{file} );
			$request->addResultLoop('item_loop', $i, 'weblink', $web_root . _proxiedUrl($_->{path}, $_->{file}));
			$i++;
		}
	}

	$request->addResult('count', $i);
	$request->addResult('offset', 0);
	
	$request->setStatusDone();
}

sub _proxiedUrl {
	my ($path, $file) = @_;

	my $pathHash = md5_hex($path);
	$cache->set( $pathHash, $path, 3600 );
	
	return "/mai/localfile/$pathHash/" . URI::Escape::uri_escape_utf8($file);
}

# search folder for supported text files, and parent folders for a biography.* file
sub _findTextFiles {
	my $previous = shift;
	my $pathObj  = Path::Class::dir($previous);
	
	my $i = 0;
	my $mask = '';
	my @files;
	
	while ( $i == 0 || $previous ne $pathObj->parent->stringify ) {
		opendir(DIR, $previous) || return [];
		
		push @files, map {
			$i = 999 if /(?:artist|bio|biogra*)\./i;    # don't walk up the tree if we've found a biography
			{
				file => $_,
				path => $previous,
			}
		} grep { 
			$_ !~ /^\._/o 
		} grep /$mask\.(?:pdf|txt|html|nfo)$/i, readdir(DIR);
		
		closedir(DIR);

		$pathObj = $pathObj->parent;
		$previous = $pathObj->stringify;
		
		last if ++$i > 3;	# don't walk up too far - most likely an artist folder is not far from the artist's album folder
		$mask = '(?:artist|bio|biogra*)';
	}
	
	return \@files;
}

sub getFileContent {
	my ($client, $cb, $params, $args) = @_;
	
	my $path = $args->{path} || '';
	my $type = __PACKAGE__->mimeType($path);

	my $content = cstring($client, 'PLUGIN_MUSICARTISTINFO_UNSUPPORTED_CT');
	
	if ( $type =~ /html/ ) {
		require HTML::FormatText;
		$content = HTML::FormatText->format_file(
			$path,
			leftmargin => 0,
		);
	}
	elsif ( $type =~ /text/ ) {
		require File::Slurp;
		$content = File::Slurp::read_file($path);
	}
	
	$content = Slim::Utils::Unicode::utf8decode($content);
	
	$cb->({
		items => Plugins::MusicArtistInfo::Plugin->textAreaItem($client, $params->{isButton}, $content)
	});
}

sub _proxyHandler {
	my ( $httpClient, $response ) = @_;
	
	return unless $httpClient->connected;
	
	my $request = $response->request;

	my ($pathHash, $file) = $request->uri->path =~ $URL_PARSER_RE;
	my $path = $cache->get($pathHash);
	$file = URI::Escape::uri_unescape($file || '');
	$path = catdir($path, $file);
	
	main::INFOLOG && $log->info("Getting file: $path");
	
	if ( !-f $path ) {
		$response->code(RC_NOT_FOUND);
		$response->content_type('text/html');
		$response->header('Connection' => 'close');
		$response->content_ref(Slim::Web::HTTP::filltemplatefile('html/errors/404.html', { path => $request->uri->path }));

		$httpClient->send_response($response);
		Slim::Web::HTTP::closeHTTPSocket($httpClient);
		return;
	}
	
	if ( $path =~ /\.nfo$/ ) {
		require Plugins::MusicArtistInfo::XMLParser;
		return Plugins::MusicArtistInfo::XMLParser->renderNFO($httpClient, $response, $path);
	}

	$response->code(RC_OK);
	Slim::Web::HTTP::sendStreamingFile( $httpClient, $response, __PACKAGE__->mimeType($path), $path, '', 'noAttachment' );

	return;
}

# this should be in Slim::Music::Info, but needs a track object there. Stupid.
sub mimeType {
	return $Slim::Music::Info::types{ Slim::Music::Info::typeFromPath($_[1]) } || 'application/octet-stream';
}

1;