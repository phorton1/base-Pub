#!/usr/bin/perl
#----------------------------------------------
# Pub::Excel::example_perl.pm
#----------------------------------------------
# An example script that hooks up with Pub/Excel/standard_perl_interface.xlsm

package Pub::Excel::example_perl;
use strict;
use warnings;
use threads;
use threads::shared;
use Win32::OLE;
use Pub::Utils;
use Pub::Excel::XL;

my $EXAMPLE_WITH_UI = 1;
my $STANDARD_EXCEL_DIR = "C:\\base\\pub\\Excel\\";
my $STANDARD_EXCEL_BOOK = "standard_perl_interface.xlsm";
my $STANDARD_EXCEL_SHEET = 1;


#---------------------------------------------
# do stuff
#---------------------------------------------


sub do_stuff
{
	my ($xl,$book) = @_;

	my $add_sleep = 1;
	my $TURN_OFF_SCREEN_UPDATING = 0;

	$book->displayMsg(0,0,"starting 'stuff'");
	my $sheet = $book->getSheet($STANDARD_EXCEL_SHEET);

	if ($sheet)
	{
		if ($TURN_OFF_SCREEN_UPDATING)
		{
			$xl->screenUpdating(0);
			$xl->calculations(0);
		}

		for (my $row=6; $row <= 10; $row++)
		{
			my $val = xlsGetValue($sheet,$row,1);
			$book->displayMsg(0,1,"xlsGetValue($row,1) = $val",0,$UTILS_COLOR_CYAN);
			xlsSetTextColor($sheet,$row,1,$row-6); # $UTILS_COLOR_CYAN);
		}
		for (my $row=6; $row <= 10; $row++)
		{
			my $val = int(rand(100));
			$book->displayMsg(0,1,"xlsSetValue($row,2,$val)",0,$UTILS_COLOR_MAGENTA);
			xlsSetValue($sheet,$row,2,$val);
			xlsSetFillColor($sheet,$row,2,$row-6+9);	# $UTILS_COLOR_YELLOW);
			sleep($add_sleep);
		}

		if ($TURN_OFF_SCREEN_UPDATING)
		{
			$xl->screenUpdating(1);
			$xl->calculations(1);
		}
	}

	$book->displayMsg(0,0,"'stuff' finished");
}




#---------------------------------------------
# main
#---------------------------------------------

LOG(0,"example_perl($EXAMPLE_WITH_UI) started");

my $xl = Pub::Excel::XL->new(0);
if ($xl)
{
	my $book = Pub::Excel::Book->new($xl,$STANDARD_EXCEL_DIR,$STANDARD_EXCEL_BOOK);
	if ($book)
	{
		my $ok = 1;
		$ok = 0 if $EXAMPLE_WITH_UI && !$book->startUI("example_perl.pm");
		if ($ok)
		{
			do_stuff($xl,$book);

			$book->setTitle("example_perl.pm done!");
			$book->endUI("All Done Here",$UTILS_COLOR_BLUE) if $EXAMPLE_WITH_UI;
			$book->close(1);
				# save_if_opened_and_needs
		}
	}
	$xl->quit();
}

LOG(0,"example_perl($EXAMPLE_WITH_UI) ending");


1;
