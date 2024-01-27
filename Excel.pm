#!/usr/bin/perl
#--------------------------------------------------------
# Pub::Excel
#--------------------------------------------------------
# Client must include Win32::OLE as appropriate.
#
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

package Pub::Excel;
use strict;
use warnings;
use Pub::Utils;
use Pub::SQLite;


my $dbg_xl = 0;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (

		$XLS_JUST_CENTER
		$XLS_JUST_LEFT
		$XLS_JUST_RIGHT

		$xlCalculationAutomatic
		$xlCalculationManual

		init_xl
		open_xls

		$xl_dirty



		$global_xl
		$global_xl_started
		$global_xl_book
		$global_xl_book_opened

		start_excel
		end_excel

		xls_LOG
		xls_display
		xls_warning
		xls_error

		excel_LOG
		excel_display
		excel_warning
		excel_error
	);
};


our $XLS_JUST_CENTER 		= -4108;
our $XLS_JUST_LEFT			= -4131;
our $XLS_JUST_RIGHT			= -4152;

our $xlCalculationAutomatic 	= -4105;
our $xlCalculationManual 	= -4135;

# our $XLS_COLOR_INDEX_DEFAULT 	= 0;
# our $XLS_COLOR_INDEX_BLACK 	= 1;
# our $XLS_COLOR_INDEX_WHITE 	= 2;
# our $XLS_COLOR_INDEX_RED 		= 3;
# our $XLS_COLOR_INDEX_GREEN 	= 4;
# our $XLS_COLOR_INDEX_BLUE 	= 5;
# our $XLS_COLOR_INDEX_YELLOW 	= 6;


our $global_xl;
our $global_xl_started = 0;

our $global_xl_book;
our $global_xl_book_opened;


our $xl_dirty = 0;
our $xl_output = 0;
our $any_xl_errors = 0;



sub utilToBgrColor
{
	my ($util_color) = @_;
	my $rgb = $utils_color_to_rgb->{$util_color};
	# print sprintf "utilToBgrColor(0x%06x) = 0x%06x\n",$util_color,$rgb;
	my $r = ($rgb & 0xff0000) >> 16;
	my $g = ($rgb & 0x00ff00);
	my $b = ($rgb & 0xff) << 16;
	return $b | $g | $r;
}



#------------------------------------------------------------
# basic Excel from Perl API
#------------------------------------------------------------
# Minimally a script must include Win32:OLE and then can
# call methods in this section to open a spreadsheet and
# deal with it.  The XLS file is opened via these reoutines,
# even if the script is called FROM the XLS file, in which
# case 'Saving' any modified XLS is deferred to the Excel UI.
# Or the script can be run from a DOSBox, with the XLS file
# closed, and can open, modify it, and save it.
#
# For threaded access to a spreadsheet, for instance from an HTTP server,
# you must "require 'OLE::Win32'" WITHIN THE THREAD on a per instance basis.
# calls init_xl and open_xls with local variables. The interaction with
# XLS does not change, if the XLS is open, then the Script SHALL defer
# the saving to the Excel UI, but otherwise, it explicitly saves the xls.
#
# It is currently up to the script to determine if it has changed the
# XLS file and if it wants to save it. That *may* change.
#
# For a standalone Perl Script, one can call init_xl with either
# local globals or the $globals provided in this module for
# convenience.  For scripts that use the 'standard' VB PerlInterface
# Module, the 'start_excel() and end_excel() methods, in a subsequent
# section, are called rather than init_xl() and open_xls() here, but
# the xls_acccessor() routines are still used.


sub init_xl
{
	display($dbg_xl,0,"init_xl()");
	my $xl_started = 0;
	my $xl = Win32::OLE->GetActiveObject('Excel.Application');
	if ($xl)
	{
		display($dbg_xl,1,"using running Excel");
	}
	else
	{
		$xl_started = 1;
		display($dbg_xl,1,"starting Excel");
		$xl = Win32::OLE->new('Excel.Application', 'Quit');
		$xl->{'Visible'} = 0;
	}
	if (!$xl)
	{
		error("Could not start Excel: ".Win32::OLE->LastError());
		return;
	}
	return ($xl,$xl_started);
}


sub open_xls
{
	my ($xl,$dir,$bookname) = @_;
	display($dbg_xl,0,"open_xls($dir,$bookname)");

	# find the workbook and use it, else open it

	my $ret_book;
	my $book_opened = 0;

	for (my $i=1; $i<=$xl->Workbooks->Count(); $i++)
	{
		my $book = $xl->Workbooks($i);
		display($dbg_xl,1,"checking book($i)=$book->{name}");
		if ($book->{name} eq $bookname)
		{
			LOG(1,"found $bookname at book($i)");
			$ret_book = $book;
			last;
		}
	}

	if (!$ret_book)
	{
		my $filename = $dir.$bookname;
		display($dbg_xl,1,"opening $filename");
		$ret_book = $xl->Workbooks->Open($filename);
		if (!$ret_book)
		{
			error("Could not open $filename");
			return;
		}
		$book_opened = 1;
		if ($ret_book->ReadOnly())
		{
			warning(0,1,"$bookname is READONLY!");
		}
	}

	return ($ret_book,$book_opened);
}




sub xlsGetValue
{
    my ($sheet,$row,$col) = @_;
    my $val = $sheet->Cells($row, $col)->{Value};
	$val = '' if !defined($val);
	$val =~ s/\s+$//g;
	$val =~ s/^\s+//g;
	return $val;
}


sub xlsSetValue
{
    my ($sheet,$row,$col,$val,$special) = @_;
	$special ||= 0;
	$val = "'".$val if $special == 1;
    $sheet->Cells($row, $col)->{Value} = $val;
	$xl_dirty = 1;
}

sub xlsSetNumberFormat
{
    my ($sheet,$row,$col,$format) = @_;
    $sheet->Cells($row, $col)->{NumberFormat} = $format;
	$xl_dirty = 1;
}

sub xlsSetJustification
{
    my ($sheet,$row,$col,$just) = @_;
    $sheet->Cells($row, $col)->{HorizontalAlignment} = $just;
	$xl_dirty = 1;
}


sub xlsSetFillColor
	# Interior->{color} takes a BGR_COLOR
{
    my ($sheet,$row,$col,$util_color) = @_;
    $sheet->Cells($row, $col)->{Interior}->{color} = utilToBgrColor($util_color);
	$xl_dirty = 1;
}


sub xlsSetTextColor
	# Font->{color} takes a BGR_COLOR
	# Could also use an XLS_COLOR index with Font->{ColorIndex}
{
    my ($sheet,$row,$col,$util_color) = @_;
    $sheet->Cells($row, $col)->{Font}->{color} = utilToBgrColor($util_color);
	$xl_dirty = 1;
}


sub xlsSetBold
{
    my ($sheet,$row,$col,$bold) = @_;
    $sheet->Cells($row, $col)->{Font}->{Bold} = $bold ? 1 : 0;
	$xl_dirty = 1;
}


sub xlsSetFormula
{
    my ($sheet,$row,$col,$formula) = @_;
	my $rc = xlrc($row,$col);
	# display(0,0,"row($row,$col) range($rc)");
	$sheet->Range($rc)->{Formula} = $formula;
	$xl_dirty = 1;
}

sub xlrc
{
    my ($row,$col) = @_;
	my $rc = ('A'..'Z')[$col-1].$row;
	return $rc;
}



sub xlsRecToDbRec
{
	my ($dbh,$table,$sheet,$row) = @_;

	my $col = 1;
	my $rec = {};
	my $fields = get_table_fields($table);
	for my $field (@$fields)
	{
		$rec->{$field} = xlsGetValue($sheet,$row,$col) || '';
		$col++;
	}

	return $rec;
}



sub xlsDBFieldCols
{
	my ($table) = @_;
	my $fields = get_table_fields($table);
	my $field_cols = {};
	my $col = 1;
	for my $field (@$fields)
	{
		$field_cols->{$field} = $col++;
	}
	return $field_cols;
}





#---------------------------------------
# pure Excel display routines
#---------------------------------------



sub xls_status
{
	my ($msg,$util_color) = @_;
	return if !$xl_output;
	$util_color ||= $UTILS_COLOR_BLACK;
	my $rgb = $utils_color_to_rgb->{$util_color};
	# printf "xls_status($util_color,0x%06x,$msg)\n",$rgb;
	$global_xl->Run("perlStatusMsg","$msg",$rgb);
}

sub xls_progress
{
	my ($msg,$util_color) = @_;
	return if !$xl_output;
	$util_color ||= $UTILS_COLOR_BLACK;
	my $rgb = $utils_color_to_rgb->{$util_color};
	# printf "xls_progress($util_color,0x%06x,$msg)\n",$rgb;
	$global_xl->Run("perlProgressMsg","$msg",$rgb);
}

sub xls_display
{
	my ($msg,$util_color) = @_;
	return if !$xl_output;
	$util_color ||= $UTILS_COLOR_BLACK;
	my $rgb = $utils_color_to_rgb->{$util_color};
	# printf "xls_display($util_color,0x%06x,$msg)\n",$rgb;
	$global_xl->Run("perlDisplay","$msg",$rgb);
}



#---------------------------------------
# Excel display routines
#---------------------------------------
# These are used from Perl Code to display messages in a
# Dos Box, and/or write them to the Log file, and/or display
# them, if possible, in the Excel Dialog. They call the standard
# Pub::Utils LOG(), display() error and warning() methods.

sub excel_status
{
	my ($msg,$util_color) = @_;
	display(0,0,"EXCEL_STATUS: $msg",1,$util_color);
	xls_status($msg,$util_color);
}

sub excel_progress
{
	my ($msg,$util_color) = @_;
	display(0,0,"EXCEL_PROGRESS(: $msg",1,$util_color);
	xls_progress($msg,$util_color);
}



sub excel_LOG
	# perlProgressMsg() also calls perlDisplay() for these
{
	my ($indent,$msg,$call_level) = @_;
	$call_level ||= 0;
	LOG($indent,$msg,$call_level+1);
	xls_display($msg,$UTILS_COLOR_BLUE);
}


sub excel_display
{
	my ($level,$indent,$msg,$call_level,$color) = @_;
	$call_level ||= 0;
	$color ||= $UTILS_COLOR_BLACK;
	display($level,$indent,$msg,$call_level+1,$color);
	xls_display($msg,$color);
}


sub excel_warning
{
	my ($level,$indent,$msg,$call_level) = @_;
	$call_level ||= 0;
	warning($level,$indent,$msg,$call_level+1);
	xls_display("WARNING: $msg",$UTILS_COLOR_YELLOW);
}


sub excel_error
{
	my ($msg,$call_level) = @_;
	$call_level ||= 0;
	error($msg,$call_level+1);
	xls_display("ERROR: $msg",$UTILS_COLOR_RED);
	$any_xl_errors = 1;
}





#---------------------------------------
# application routines
#---------------------------------------


sub end_excel
{
	my ($status_msg,$status_color) = @_;

	$status_msg ||= 'Done.';
	$status_color ||= $UTILS_COLOR_BLACK;

	LOG(0,"end_excel($any_xl_errors,$status_msg,$status_color) called");

	my $progress_color = $UTILS_COLOR_GREEN;
	my $progress_result = "Finished with no errors";
	if ($any_xl_errors)
	{
		$progress_color = $UTILS_COLOR_RED;
		$progress_result = "Finished with ERRORS !!";
		warning(0,0,"end_excel returning 'ERROR(s)!!");
	}
	excel_progress($progress_result,$progress_color);

	my $rgb = $utils_color_to_rgb->{$status_color};
	$global_xl->Run("perlEnd",$status_msg,$rgb) if $global_xl;

	$global_xl_book = undef;
	$global_xl->Quit() if $global_xl && $global_xl_started;
	$global_xl = undef;
	LOG(0,"end_budget_xlsm() finished");
}



sub start_excel
{
	my ($dir,$bookname) = @_;
	LOG(0,"start_excel($dir,$bookname)");

	($global_xl,$global_xl_started) = init_xl();

	if (!$global_xl)
	{
		error("Could not start Excel: ".Win32::OLE->LastError());
		return;
	}

	($global_xl_book,$global_xl_book_opened) =
		open_xls($global_xl,$dir,$bookname);

	if (!$global_xl_book)
	{
		excel_error("Could not open $bookname");
		$global_xl->Quit() if $global_xl_started;
		$global_xl = undef;
		return;
	}
	if ($global_xl_book->ReadOnly())
	{
		excel_error("$bookname is READONLY");
		if (1)
		{
			$global_xl_book->Close(0);
			$global_xl_book = undef;
			$global_xl->Quit() if $global_xl_started;
			$global_xl_started = undef;
		}
		return;
	}

	# from here on out we don't close budget or excel

	$xl_output = $global_xl->Run("perlStart","$$");
		# calls perlStateMsg()

	LOG(1,"perlStart($$) returned "._def($xl_output));
	LOG(1,"start_excel() returning 1");
	return 1;
}




1;
