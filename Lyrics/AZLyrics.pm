package Plugins::MusicArtistInfo::Lyrics::AZLyrics;

use strict;

use File::Spec::Functions qw(catdir);
use FindBin qw($Bin);
use lib catdir($Bin, 'Plugins', 'MusicArtistInfo', 'lib');
use HTML::Entities;
use HTML::TreeBuilder;

use constant BASE_URL => 'https://www.azlyrics.com/lyrics/';
use constant GET_LYRICS_URL => BASE_URL . '%s/%s.html';

sub getLyrics {
	my ( $class, $args, $cb ) = @_;

	my $artist = $args->{artist};
	$artist =~ s/^the //i;
	$artist = _cleanupName($artist);
	$artist = 'thethe' if $artist eq 'the';
	my $title  = _cleanupName($args->{title});
	my $url    = sprintf(GET_LYRICS_URL, $artist, $title);

	Plugins::MusicArtistInfo::Common->call($url, sub {
		my $result = shift;

		my $tree = HTML::TreeBuilder->new;
		$result = Slim::Utils::Unicode::utf8decode($result);
		$tree->parse_content( $result );

		my $container = $tree->look_down('_tag', 'div', 'class', 'col-xs-12 col-lg-8 text-center');

		my @content = $container->look_down('_tag', 'div') if $container;
		my $lyrics;

		foreach my $div (@content) {
			next if $div->attr('class');

			$lyrics = $div->as_HTML;
			$lyrics =~ s/<br\s*\/>/\n/g;
			$lyrics =~ s/<\/?.*?>//g;
			$lyrics =~ s/^ *//mg;
			$lyrics = decode_entities($lyrics);

			last;
		}

		# let's mimic ChartLyric's data format
		$cb->($lyrics ? {
			song => $args->{title},
			artist => $args->{artist},
			lyrics => $lyrics
		} : undef);
	}, {
		timeout => 5,
		ignoreError => [404]
	});

	return;
}

sub _cleanupName {
	my $name = $_[0];

	$name =~ s/&/and/g;
	$name = Slim::Utils::Text::ignorePunct($name);
	$name = lc(Slim::Utils::Unicode::utf8toLatin1Transliterate($name));
	$name =~ s/[^a-z0-9]//g;

	return $name;
}

1;
