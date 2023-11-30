package Plugins::MusicArtistInfo::Parser::LRC;

use strict;

use File::Slurp qw(read_file);

use Slim::Utils::Log;

# parse lyrics file according to https://en.wikipedia.org/wiki/LRC_(file_format)

my $log = logger('plugin.musicartistinfo');

sub parse {
	my ($class, $path) = @_;

	return unless -r $path;

	if (-s $path > 100_000) {
		$log->warn('File is >100kB - likely not lyrics. Skipping ' . $path);
		return;
	}

	return $class->strip(scalar read_file($path))
}

sub strip {
	my ($class, $content, $keepTimestamps) = @_;

	# only show empty lines if they come in line, but not at the top of the file
	my $textFound = 0;
	return join("\n", grep {
		$textFound ||= /\w/;
		$textFound;
	} map {
		# remove some metadata
		s/\[(?:ar|al|ti|au|length|by|offset|re|ve):.*?\]//g;
		# remove timestamps
		s/^\[\d+.*?\]//g unless $keepTimestamps;
		# Enhanced LRC format is an extension of Simple LRC Format developed by the designer of A2 Media Player
		s/<\d+:\d+\.\d+>//g;
		$_;
	} split($/, $content));
}


1;