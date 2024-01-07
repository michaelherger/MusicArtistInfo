#!/usr/bin/perl

use strict;

use Data::Dumper;
use JSON;
use LWP::UserAgent;

my $albums;

BEGIN {
	my $file = 'albums.json';

	$albums = decode_json(do {
		local $/ = undef;
		open my $fh, "<", $file or die "could not open $file: $!";
		<$fh>;
	});
}

use Test::Simple tests => scalar @$albums;

use constant URL => 'http://localhost:9000/jsonrpc.js';
use constant BODY => '{"id":0,"params":["",["musicartistinfo","albumreview","artist:%s","album:%s","lang:%s","html:1"]],"method":"slim.request"}';

my $ua = LWP::UserAgent->new(
	timeout => 10,
);
$ua->default_header('Content-Type' => 'text/plain');

my $req = HTTP::Request->new('POST' => URL);

foreach my $album (@$albums) {
	$req->content(sprintf(BODY, $album->{artist}, $album->{title}, $album->{lang} || 'en'));
	my $response = $ua->request($req);

	# warn Dumper($response->decoded_content);
	ok($response->decoded_content =~ /\Q$album->{expected}\E/, $album->{artist} . ' - ' . $album->{title});
}


1;