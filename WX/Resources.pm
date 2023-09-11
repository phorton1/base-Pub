#!/usr/bin/perl
#------------------------------------------
# Pub::WX::Resources
#
# Defines the the title, command IDs and Menus available to
# Pub::WX programs.  Program instances merge their resources
# into the $resources hash.


package Pub::WX::Resources;
use strict;
use warnings;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (
        $resources
        $ID_SEPARATOR
        $CLOSE_ALL_PANES
        $CLOSE_OTHER_PANES
    );
}

our (
    $ID_SEPARATOR,
	$CLOSE_ALL_PANES,
	$CLOSE_OTHER_PANES,
) = (7238..7777);


my @view_menu = (
	$CLOSE_ALL_PANES,
	$CLOSE_OTHER_PANES );

my %command_data = (
	$CLOSE_ALL_PANES    => ['Close All',		'Close all open windows' ],
	$CLOSE_OTHER_PANES  => ['Close Others', 	'Close all open windows except the current one'],
);


our $resources = {
    app_title    => 'Generic Application',
    view_menu    => \@view_menu,
    command_data => \%command_data,
};


1;
