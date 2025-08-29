package Plugins::MusicArtistInfo::Parser::Markdown;

use strict;

use File::Slurp;
use HTML::FormatText;
use Text::MultiMarkdown;

sub parseToHTML {
	my ($class, $path) = @_;
	my $content = ref $path ? $$path : File::Slurp::read_file($path);
	return Text::MultiMarkdown->new->markdown($content);
}

sub parse {
	my ($class, $path) = @_;
	my $html = $class->parseToHTML($path);
	return HTML::FormatText->format_string(
		$html,
		leftmargin => 0,
	);
}

sub renderAsHTML {
	my ($class, $httpClient, $response, $path) = @_;

	my $content = $class->parseToHTML($path);

	$response->content_type('text/html');
	$response->header('Connection' => 'close');
	$response->content_ref(Slim::Web::HTTP::filltemplatefile('/plugins/MusicArtistInfo/generic.html', {
		title => $path,
		webroot => '/',
		path => $response->request->uri->path,
		content => $content,
	}));

	$httpClient->send_response($response);
	Slim::Web::HTTP::closeHTTPSocket($httpClient);
	return;
}


1;
