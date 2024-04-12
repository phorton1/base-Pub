#!/bin/bash

echo Setting up rPi Perl dependencies

# Pub::Utils

sudo apt-get install libdate-calc-perl
sudo apt-get install libjson-perl
sudo apt-get install libcrypt-rc4-perl
sudo apt-get install libio-socket-ssl-perl
sudo apt-get install libwww-perl 
sudo apt-get install libsys-meminfo-perl
sudo apt-get install libmime-types-perl
sudo apt-get install libdigest-sha-perl
sudo apt-get install libfile-mimeinfo-perl

# apps/myIOTServer

sudo apt-get install libprotocol-websocket-perl

# apps/artisan

sudo apt-get install libio-socket-multicast-perl
sudo apt-get install libxml-simple-perl
sudo apt-get install libdbi-perl
sudo apt-get install libaudio-wma 
sudo apt-get install libmp4-info-perl
sudo apt-get install libdbd-sqlite3-perl
sudo apt-get install libterm-readkey-perl

# apps/inventory (Pub::Database on linux)

sudo apt-get install libarchive-zip-perl
sudo apt-get install libdbd-sqlite3-perl
