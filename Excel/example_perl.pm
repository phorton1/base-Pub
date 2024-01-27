#!/usr/bin/perl
#----------------------------------------------
# Pub::Excel::example_perl.pm
#----------------------------------------------
# An example script that hooks up with Pub/Excel/standard_perl_interface.xlsm

package Pub::Excel::example_perl;
use strict;
use warnings;
use Pub::Utils;
use Pub::Excel;
use Win32::OLE;
# use Win32::OLE::Variant qw(VT_DATE);
	# my $VT_DATE = 7;

my $EXAMPLE_WITH_UI = 1;
	# if 0, just do some excel stuff
	# if 1, invoke (or expects) the dialog
my $STANDARD_EXCEL_DIR = "C:\\base\\pub\\Excel\\";
my $STANDARD_EXCEL_BOOK = "standard_perl_interface.xlsm";
my $STANDARD_EXCEL_SHEET = 1;



#---------------------------------------------
# starting
#---------------------------------------------

LOG(0,"example_perl($EXAMPLE_WITH_UI) started");


if ($EXAMPLE_WITH_UI)
{
	exit(0) if !start_excel($STANDARD_EXCEL_DIR,$STANDARD_EXCEL_BOOK);
}
else
{
	($global_xl,$global_xl_started) = init_xl();

	if (!$global_xl)
	{
		error("Could not start Excel: ".Win32::OLE->LastError());
		return;
	}

	($global_xl_book,$global_xl_book_opened) =
		open_xls($global_xl,$STANDARD_EXCEL_DIR,$STANDARD_EXCEL_BOOK);

	if (!$global_xl_book)
	{
		error("Could not open $STANDARD_EXCEL_BOOK");
		$global_xl->Quit() if $global_xl_started;
		$global_xl = undef;
		exit(0);
	}
	if ($global_xl_book->ReadOnly())
	{
		warning("$STANDARD_EXCEL_BOOK is READONLY");
	}

	display(0,1,"$STANDARD_EXCEL_BOOK opened with no UI");
}




#---------------------------------------------
# do stuff
#---------------------------------------------

my $add_sleep = 1;
my $TURN_OFF_SCREEN_UPDATING = 0;

excel_display(0,0,"starting 'stuff'");
my $sheet = $global_xl_book->Sheets($STANDARD_EXCEL_SHEET);


if ($TURN_OFF_SCREEN_UPDATING)
{
	$global_xl->{ScreenUpdating} = 0;
	$global_xl->{Calculation} = $xlCalculationManual;
}


for (my $row=6; $row <= 10; $row++)
{
	my $val = xlsGetValue($sheet,$row,1);
	excel_display(0,1,"xlsGetValue($row,1) = $val",0,$UTILS_COLOR_CYAN);
	xlsSetTextColor($sheet,$row,1,$row-6); # $UTILS_COLOR_CYAN);
}
for (my $row=6; $row <= 10; $row++)
{
	my $val = int(rand(100));
	excel_display(0,1,"xlsSetValue($row,2,$val)",0,$UTILS_COLOR_MAGENTA);
	xlsSetValue($sheet,$row,2,$val);
	xlsSetFillColor($sheet,$row,2,$row-6+9);	# $UTILS_COLOR_YELLOW);
	sleep($add_sleep);
}


if ($TURN_OFF_SCREEN_UPDATING)
{
	$global_xl->{ScreenUpdating} = 1;
	$global_xl->{Calculation} = $xlCalculationAutomatic;
}

excel_display(0,0,"'stuff' finished");


#---------------------------------------------
# ending
#---------------------------------------------


if ($EXAMPLE_WITH_UI)
{
	end_excel("All good here",$UTILS_COLOR_BLUE);
}
else
{
	if ($xl_dirty && $global_xl_started && !$global_xl_book->ReadOnly())
	{
		display(0,0,"saving dirty started non-readonly $STANDARD_EXCEL_BOOK");
		$global_xl_book->Save() ;
	}

	$global_xl_book = undef;

	if ($global_xl_started)
	{
		display(0,0,"quitting started $STANDARD_EXCEL_BOOK");
		$global_xl->Quit();
	}

	$global_xl = undef;
}






LOG(0,"example_perl($EXAMPLE_WITH_UI) ending");



1;
