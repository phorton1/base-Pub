#-------------------------------------------------------
# fileServer.pm - a local file Server
#-------------------------------------------------------

use strict;
use warnings;
use threads;
use threads::shared;
use lib '.';
use Pub::FS::Server;
use Pub::FS::Session;
use Pub::Utils;

my $file_server = Pub::FS::Server->new();

while (1)
{
	sleep(10);
}

1;
