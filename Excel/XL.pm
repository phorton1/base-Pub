#!/usr/bin/perl
#--------------------------------------------------------
# Pub::Excel::XL
#--------------------------------------------------------
# This module provides read/write acesss to Excel Workbooks and Worksheets
# from Perl Scripts, including from Perl threads and HTTP Servers, and
# can provide a standardized  mechanism for supporting a DosBox-lik UI in
# Workbooks that import the PerlInterface VBA script and UserForm.
#
# The module works with Workbooks that are already opened in the MS Windows
# UI by an instance of Excel, and by convention does NOT automatically
# save modified workbooks that were already open when the script was invoked.
#
# Perl Scripts are called from Excel using the visual basic 'system'
# command. Minimally, such a script uses a logfile for debugging when
# run 'headless' from Excel.  More sophisticated spreadsheets include
# the standard 'PerlInterface' VBA module and UserForm which provides
# a callback UI, somewhat equivilant to a DosBox, for the Perl Script
# to report Status and Progress, display messages warnings, and errors.
#
# COLORS
#
# We standardize on UTIL_COLOR_XXXX indexes, which are mapped to RGB
# colors in Pub::Utils, and then converted to to BGR colors for Excel.
# Excel also uses COLOR_INDEXES which we could map directly from
# UTIL_COLOR indexes.

package Pub::Excel::XL;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use Pub::Excel::xlUtils;
use Pub::Excel::Book;


my $dbg_xl = 0;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (
	);
	push @EXPORT,@Pub::Excel::xlUtils::EXPORT;

};


our $XLS_JUST_CENTER 		= -4108;
our $XLS_JUST_LEFT			= -4131;
our $XLS_JUST_RIGHT			= -4152;

our $xlCalculationAutomatic 	= -4105;
our $xlCalculationManual 	= -4135;


# The API to Excel and Workbooks is complicated.
#
# A given Workbook may ALREADY BE OPEN in the Windows UI.
# If there is no Excel running, you need to start Excel in order to open a Workbook.
# If Excel is already running, you might want to create another one.
# Controlling the visibiliity of a Workbook is best done on the Excel object.
#	Excel can be started invisible.
#	A Workbook *could* be made invisible by setting its Window invisible in its Excel.
#	but a visible Excel will open a Workbook visibily, and thus 'flash' if it is henceforth
#   made invisible.
#
# This goes to READONLY and utilizing the SAVED, or the UNSAVED data.
# If you use an open Excel with an open Workbook you read and write to the UNSAVED data.
#
# So, it all depends on what you want to do, how you want the SS to appear,
# and gets even more complicated with scripts that want to access multiple
# Workbooks.


sub new
{
	my ($class,$visible_if_opened) = @_;
	$visible_if_opened ||= 0;

	display($dbg_xl,0,"XL::new($visible_if_opened)");
	my $this = {
		started => 0,
		opened  => 0,
		excel   => '' };
	bless $this,$class;

	$this->{excel} = Win32::OLE->GetActiveObject('Excel.Application');
	if ($this->{excel})
	{
		display($dbg_xl,1,"using running Excel");
	}
	else
	{
		$this->{started} = 1;
		display($dbg_xl,1,"starting Excel");
		$this->{excel} = Win32::OLE->new('Excel.Application', 'Quit');
		$this->{excel}->{'Visible'} = $visible_if_opened;
	}
	if (!$this->{excel})
	{
		error("Could not start Excel: ".Win32::OLE->LastError());
		return;
	}

	return $this;
}


sub quit
	# quits excel if it was started
{
	my ($this) = @_;
	display($dbg_xl,0,"quit($this->{started})");
	$this->{excel}->Quit() if $this->{started};
	$this->{excel} = undef;
}


sub openBook
{
	my ($this,$dir,$bookname) = @_;
	display($dbg_xl,0,"openBook($dir,$bookname)");
	my $book = Pub::Excel::Book->new($this,$dir,$bookname);
	return $book;
}


sub screenUpdating
{
	my ($this,$on) = @_;
	$this->{excel}->{ScreenUpdating} = $on;
}

sub calculations
{
	my ($this,$on) = @_;
	$this->{excel}->{Calculation} = $on ?
		$xlCalculationAutomatic :
		$xlCalculationManual;
}





1;
