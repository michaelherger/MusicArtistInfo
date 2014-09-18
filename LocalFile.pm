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

use Slim::Menu::AlbumInfo;
use Slim::Menu::FolderInfo;
use Slim::Menu::TrackInfo;

use Slim::Utils::Cache;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;

use Slim::Web::Pages;

my $log   = logger('plugin.musicartistinfo');
my $prefs = preferences('plugin.musicartistinfo');
my $cache = Slim::Utils::Cache->new;

my $URL_PARSER_RE      = qr{mai/localfile/([a-f\d]+)/(.*)$};

sub init { 
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

	# only deal with local media
	$url = $track->url if !$url && $track;
	return unless $url && $url =~ /^file:\/\//i;
	
	my $path = Slim::Utils::Misc::pathFromFileURL($url);
	
	if (! -d $path) {
		$path = dirname( $path );
	}
	
	opendir(DIR, $path) || return;
	my @files = grep { $_ !~ /^\._/o } grep /\.(?:pdf|txt|html?)$/io, readdir(DIR);
	closedir(DIR);

	return unless scalar @files;
	
	my $items = [ map {
		my $pathHash = md5_hex($path);
		$cache->set( $pathHash, $path, 86400 );

		{
			# XXX - how can we hide this from the players?
			type  => 'text',
			name  => $_,
			weblink => "/mai/localfile/$pathHash/$_",
		}
	} @files ];
	
	return {
		name => cstring($client, 'PLUGIN_MUSICARTISTINFO_LOCAL_FILES'),
		type => 'outline',
		items => $items,
	};	
}

sub _proxyHandler {
	my ( $httpClient, $response ) = @_;
	
	return unless $httpClient->connected;
	
	my $request = $response->request;

	my ($pathHash, $file) = $request->uri->path =~ $URL_PARSER_RE;
	my $path = $cache->get($pathHash);
	$path = catdir($path, $file);
	
	if ( !-f $path ) {
		$response->code(RC_NOT_FOUND);
		$response->content_type('text/html');
		$response->header('Connection' => 'close');
		$response->content_ref(Slim::Web::HTTP::filltemplatefile('html/errors/404.html', { path => $request->uri->path }));

		$httpClient->send_response($response);
		Slim::Web::HTTP::closeHTTPSocket($httpClient);
		return;
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