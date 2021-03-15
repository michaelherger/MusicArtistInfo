package Plugins::MusicArtistInfo::AllMusic::Common;

use strict;
use Exporter::Lite;

BEGIN {
	use constant BASE_URL         => 'http://www.allmusic.com/';
	use constant ALBUMSEARCH_URL  => BASE_URL . 'search/albums/%s%%2C%%20%s';

	use Exporter::Lite;
	our @EXPORT_OK = qw( BASE_URL ALBUMSEARCH_URL );
}

1;