package Plugins::MusicArtistInfo::Lyrics::Genius;

use strict;

use File::Spec::Functions qw(catdir);
use FindBin qw($Bin);
use lib catdir($Bin, 'Plugins', 'MusicArtistInfo', 'lib');
use HTML::Entities;
use HTML::FormatText;
use HTML::TreeBuilder;

use constant BASE_URL => 'https://genius.com/';
use constant GET_LYRICS_URL => BASE_URL . '%s-%s-lyrics';

sub getLyrics {
	my ( $class, $args, $cb ) = @_;

	my $artist = $args->{artist};
	$artist =~ s/^the //i;
	$artist = _cleanupName($artist);
	$artist = 'thethe' if $artist eq 'the';
	my $title  = _cleanupName($args->{title});

	my $url    = sprintf(GET_LYRICS_URL, $artist, $title);
	$url =~ s/ /-/g;

	Plugins::MusicArtistInfo::Common->call($url, sub {
		my $result = shift;

		my $tree = HTML::TreeBuilder->new;
		$tree->parse_content( $result );

		my $container = $tree->look_down('_tag', 'div', 'class', 'lyrics');

		my @content = $container->look_down('_tag', 'p') if $container;

		my $lyrics;

		foreach my $p (@content) {
			$lyrics = HTML::FormatText->format_string(
				$p->as_HTML,
				leftmargin => 0,
			);

			last if $lyrics;
		}

		# # let's mimic ChartLyric's data format
		$cb->($lyrics ? {
			song => $args->{title},
			artist => $args->{artist},
			lyrics => Slim::Utils::Unicode::utf8decode($lyrics)
		} : undef);
	}, {
		timeout => 5,
		ignoreError => [404]
	});

	return;
}

sub _cleanupName {
	my $name = $_[0];

	$name =~ s/['"`()]//g;
	$name =~ s/&/and/g;
	$name = lc(Slim::Utils::Unicode::utf8toLatin1Transliterate($name));
	$name = Slim::Utils::Text::ignorePunct($name);

	return $name;
}

1;
