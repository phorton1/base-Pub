#!/usr/bin/perl
#--------------------------------------------------------
# Pub::Excel
#--------------------------------------------------------
# Client must include Win32::OLE as appropriate

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

		$XLS_COLOR_DEFAULT
		$XLS_COLOR_BLACK
		$XLS_COLOR_WHITE
		$XLS_COLOR_RED
		$XLS_COLOR_GREEN
		$XLS_COLOR_BLUE
		$XLS_COLOR_YELLOW

		init_xl
		open_xls

		xlsGetValue
		xlsSetValue
		xlsSetNumberFormat
		xlsSetJustification
		xlsSetFillColor
		xlsSetTextColor
		xlsSetBold
		xlsSetFormula
		xlrc
		xlsRecToDbRec
		xlsDBFieldCols

		start_excel;
		end_excel;

		xls_display
		xls_state_msg
		xls_status_msg
		xls_progress_msg

		perl_progress_msg
		perl_state_msg
		perl_status_msg
		perl_display
		perl_error

		excel_progress_msg
		excel_state_msg
		excel_status_msg
		excel_display
		excel_error
	);
};


our $XLS_JUST_CENTER 		= -4108;
our $XLS_JUST_LEFT			= -4131;
our $XLS_JUST_RIGHT			= -4152;

our $xlCalculationAutomatic 	= -4105;
our $xlCalculationManual 	= -4135;

our $XLS_COLOR_DEFAULT 	= 0;
our $XLS_COLOR_BLACK 	= 1;
our $XLS_COLOR_WHITE 	= 2;
our $XLS_COLOR_RED 		= 3;
our $XLS_COLOR_GREEN 	= 4;
our $XLS_COLOR_BLUE 	= 5;
our $XLS_COLOR_YELLOW 	= 6;


our $global_xl;
our $global_xl_started = 0;

our $global_xl_book;
our $global_xl_book_opened;


our $xl_output = 0;
our $any_xl_errors = 0;


# our $output_dir = "/junk/_banks";



my $shutting_down = 0;
	# re-entrancy control
	# number of new transactions added







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
}

sub xlsSetNumberFormat
{
    my ($sheet,$row,$col,$format) = @_;
    $sheet->Cells($row, $col)->{NumberFormat} = $format;
}

sub xlsSetJustification
{
    my ($sheet,$row,$col,$just) = @_;
    $sheet->Cells($row, $col)->{HorizontalAlignment} = $just;
}


sub xlsSetFillColor
	# Takes a HEX_COLOR
{
    my ($sheet,$row,$col,$hex_color) = @_;
    $sheet->Cells($row, $col)->{Interior}->{color} = $hex_color;
}


sub xlsSetTextColor
	# takes a XLS_COLOR index
{
    my ($sheet,$row,$col,$color_index) = @_;
    $sheet->Cells($row, $col)->{Font}->{ColorIndex} = $color_index;
}


sub xlsSetBold
	# takes a XLS_COLOR index
{
    my ($sheet,$row,$col,$bold) = @_;
    $sheet->Cells($row, $col)->{Font}->{Bold} = $bold ? 1 : 0;
}


sub xlsSetFormula
{
    my ($sheet,$row,$col,$formula) = @_;
	my $rc = xlrc($row,$col);
	# display(0,0,"row($row,$col) range($rc)");
	$sheet->Range($rc)->{Formula} = $formula;
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
# Display messages in Dialog Box in Spreadsheet.
# $xl_output is 0 if start_excel() was unable to
# initiate contact with the dialog box.
#
# These methods are generally not directly called by
# Perl Client Code, but are EXPORTED for testing.


sub xls_progress_msg
{
	my ($msg,$color) = @_;
	return if !$xl_output;
	$color ||= "black";
	$global_xl->Run("perlProgressMsg","$msg\n",$color);
}

sub xls_state_msg
{
	my ($msg,$color) = @_;
	return if !$xl_output;
	$color ||= "black";
	$global_xl->Run("perlStateMsg","$msg\n",$color);
}

sub xls_status_msg
{
	my ($msg,$color) = @_;
	return if !$xl_output;
	$color ||= "black";
	$global_xl->Run("perlStatusMsg","$msg\n",$color);
}

sub xls_display
{
	my ($msg,$color) = @_;
	return if !$xl_output;
	$color ||= "black";
	$global_xl->Run("perlDisplay","$msg\n",$color);
}



#---------------------------------------
# Perl display routines called from Excel
#---------------------------------------
# I'm not sure exactly what these are, or why they are here.

sub perl_progress_msg
{
	my ($class,$msg,$color) = @_;
	$color ||= "black";
	excel_progress_msg($msg,$color);
}


sub perl_state_msg
{
	my ($class,$msg,$color) = @_;
	$color ||= "black";
	excel_state_msg($msg,$color);
		# doubled (engine_display() called)
		# in Scripted::Engine::state_msg()
}


sub perl_status_msg
{
	my ($class,$msg,$color) = @_;
	$color ||= "black";
	excel_status_msg($msg,$color);
}


sub perl_display
{
	my ($class,$msg,$color) = @_;
	$color ||= "black";
	excel_display($msg,$color);
}


sub perl_error
{
	my ($class,$msg) = @_;
	excel_state_msg("ERROR: $msg","red");
	excel_display("ERROR: $msg","red");
	$any_xl_errors++;
}



#---------------------------------------
# Excel display routines
#---------------------------------------
# These are used from Perl Code to display messages in a
# Dos Box, and/or write them to the Log file, and/or display
# them, if possible, in the Excel Dialog.#
# Also call error(), LOG(), display() or warning()
# if !$REDIRECT_DISPLAY_TO_EXCEL which would double them


sub excel_progress_msg
	# perlProgressMsg() also calls perlDisplay() for these
{
	my ($msg,$color,$level) = @_;
	$level ||= 0;
	$color ||= "purple";
	LOG(-1,$msg,$level+1);
	xls_progress_msg($msg,$color);
}


sub excel_state_msg
{
	my ($msg,$color,$level) = @_;
	$level ||= 0;
	$color ||= "blue";
	LOG(0,$msg,$level+1);
	xls_state_msg($msg,$color);
	xls_display($msg,$color);
		# doubled here
}


sub excel_status_msg
{
	my ($msg,$color,$level) = @_;
	$level ||= 0;
	$color ||= "black";
	display(0,0,$msg,$level+1);
	xls_status_msg($msg,$color);
}


sub excel_display
{
	my ($msg,$color,$level) = @_;
	$level ||= 0;
	$color ||= "black";
	display(0,0,$msg,$level+1);
	xls_display($msg,$color);
}



sub excel_error
{
	my ($msg,$level) = @_;
	$level ||= 0;
	error($msg,$level+1);
	$msg = "ERROR: $msg";
	xls_state_msg($msg,'red');
	xls_display($msg,'red');
	$any_xl_errors = 1;
}





#---------------------------------------
# application routines
#---------------------------------------


sub end_excel
{
	my ($state_result,$state_color) = @_;

	$state_result ||= 'Done.';
	$state_color ||= 'black';

	LOG(0,"end_excel($any_xl_errors,$state_result,$state_color) called");

	my $progress_color = "green";
	my $progress_result = "Finished with no errors";
	if ($any_xl_errors)
	{
		$progress_color = "red";
		$progress_result = "Finished with ERRORS !!";
		warning(0,0,"end_excel returning 'ERROR(s)!!");
	}
	excel_progress_msg($progress_result,$progress_color);

	$global_xl->Run("perlEnd",$state_result,$state_color) if $global_xl;
		# calls perlStateMsg()

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
		perl_error("Could not start Excel: ".Win32::OLE->LastError());
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

	$xl_output = $global_xl_started->Run("perlStart","$$");
		# calls perlStateMsg()

	LOG(1,"perlStart($$) returned "._def($xl_output));
	LOG(1,"start_excel() returning 1");
	return 1;
}







1;
