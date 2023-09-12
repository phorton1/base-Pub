#!/usr/bin/perl
#-------------------------------------------------------------
# fileClientResources.pm
#-------------------------------------------------------------
# All appBase applications may provide resources that contain the
# app_title, main_menu, command_data, notebook_data, and so on.
# Derived classes should merge their values into the base
# class $resources member.

use lib '/base/apps/file2';

package Pub::FS::fileClientResources;
use strict;
use warnings;
use Pub::WX::Resources;

BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (
        $resources

		$COMMAND_CONNECT
		$ID_CLIENT_WINDOW

        $COMMAND_XFER
        $COMMAND_DELETE
        $COMMAND_RENAME
        $COMMAND_REFRESH
        $COMMAND_MKDIR
        $COMMAND_RECONNECT
        $COMMAND_DISCONNECT
    );
}

# derived class decides if wants viewNotebook
# commands added to the view menu, by setting
# the 'command_id' member on the notebook info.

our (
	$COMMAND_CONNECT,
	$ID_CLIENT_WINDOW,

    $COMMAND_XFER,
    $COMMAND_DELETE,
    $COMMAND_RENAME,
    $COMMAND_MKDIR,
    $COMMAND_REFRESH,
    $COMMAND_RECONNECT,
	$COMMAND_DISCONNECT )= (10000..11000);


# Command data for this application.
# Notice the merging that takes place

my %command_data = (%{$resources->{command_data}},

	# the only command at this time

	$COMMAND_CONNECT => ['Connect', 'Connect to a Host' ],

	# context menu commands

    $COMMAND_XFER       => ['Xfer',     'Upload/Download file/directories'],
    $COMMAND_DELETE     => ['Delete',   'Delete files/directories'],
    $COMMAND_RENAME     => ['Rename',   'Rename files/directories'],
    $COMMAND_REFRESH    => ['Refresh',  'Refresh the contents of this pane'],
    $COMMAND_MKDIR      => ['New Folder','Create a new folder'],
    $COMMAND_RECONNECT  => ['Reconnect',  'Connect to the server'],
    $COMMAND_DISCONNECT => ['Disconnect','Disconnect from the server'],
);


# Pane data for lookup of notebook by window_id

my %pane_data = (
	$ID_CLIENT_WINDOW	=> ['client_window',	'content'	],
);


# Notebook data includes an array "in order",
# and a lookup by id for notebooks to be opened by
# command id's

my %notebook_data = (
	content  => {
        name => 'content',
        row => 1,
        pos => 1,
        direction => '',
        title => 'Content Notebook' },
);


my @notebooks = (
    $notebook_data{content});


my %notebook_name = (
);


#-------------------------------------
# Menus
#-------------------------------------

my @main_menu = (
    'view_menu,&View' );

unshift @{$resources->{view_menu}},$ID_SEPARATOR;
unshift @{$resources->{view_menu}},$COMMAND_CONNECT;



my @win_context_menu = (
    $COMMAND_XFER,
       $ID_SEPARATOR,
    $COMMAND_DELETE,
    $COMMAND_RENAME,
       $ID_SEPARATOR,
    $COMMAND_REFRESH,
       $ID_SEPARATOR,
    $COMMAND_MKDIR,
       $ID_SEPARATOR,
    $COMMAND_RECONNECT,
    $COMMAND_DISCONNECT,
);


#-----------------------------------------
# Merge and reset the single public object
#-----------------------------------------

$resources = { %$resources,
    app_title       => 'fileCllient',

    command_data    => \%command_data,
    notebooks       => \@notebooks,
    notebook_data   => \%notebook_data,
    notebook_name   => \%notebook_name,
    pane_data       => \%pane_data,

    main_menu       => \@main_menu,
    win_context_menu   => \@win_context_menu,

};


1;
