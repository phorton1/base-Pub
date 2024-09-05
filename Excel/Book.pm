#!/usr/bin/perl
#--------------------------------------------------------
# Pub::Excel::Book
#--------------------------------------------------------
# To design the form I had to dig up a new 'tool' in the
# toolbar by selecting "Microsoft Web Browser" from the
# right-click "Additional Controls" dialog.

package Pub::Excel::Book;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;


my $dbg_book = 0;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (
	);
};



sub open
{
	my ($class,$xl,$dir,$bookname) = @_;
	display($dbg_book,0,"Book::open($dir,$bookname)");

	my $this = {
		xl => $xl,
		bookname => $bookname,
		workbook => '',
		opened => 0,
		opened_dirty => 0,
		read_only => 0,
		any_errors => 0,
		ui_started => 0 };
	bless $this,$class;

	for (my $i=1; $i<=$xl->{excel}->Workbooks->Count(); $i++)
	{
		my $book = $xl->{excel}->Workbooks($i);
		display($dbg_book+1,1,"checking book($i)=$book->{name}");
		if ($book->{name} eq $bookname)
		{
			LOG(1,"found $bookname at book($i)");
			$this->{workbook} = $book;
			last;
		}
	}

	if (!$this->{workbook})
	{
		my $filename = "$dir\\$bookname";
		display($dbg_book,1,"opening $filename");
		$this->{workbook} = $xl->{excel}->Workbooks->Open($filename);
		if (!$this->{workbook})
		{
			error("Could not open $filename");
			return;
		}
		$this->{opened} = 1;
		if ($this->{workbook}->ReadOnly())
		{
			$this->{read_only} = 1;
			warning(0,1,"$bookname is READONLY!");
		}
	}

	$this->{opened_dirty} = $this->{workbook}->{saved} ? 0 : 1;
	return $this;
}


sub getSheet
{
	my ($this,$sheet_name_or_num) = @_;
	return error("No workbook in getSheet")
		if !$this->{workbook};

	my $sheet;
	if ($sheet_name_or_num !~ /^\d+$/)
	{
		my $count = $this->{workbook}->{Sheets}->Count();
		for my $sheet_num (1..$count)
		{
			my $s = $this->{workbook}->Sheets($sheet_num);
			if ($s->{name} eq $sheet_name_or_num)
			{
				$sheet = $s;
				last;
			}
		}
	}
	else
	{
		$sheet = $this->{workbook}->Sheets($sheet_name_or_num);
	}
	if (!$sheet)
	{
		$this->errorMsg("Could not get book($this->{bookname}) sheet($sheet_name_or_num)");
		return '';
	}
	return $sheet;
}



sub close
{
	my ($this,$save_if_opened_and_needs) = @_;
	if (!$this->{workbook})
	{
		error("close($this->{bookname}) called without workbook");
	}
	else
	{
		my $needs_save = $this->{workbook}->{saved} ? 0 : 1;
		display($dbg_book,0,"close() opened($this->{opened}) needs_save($needs_save)");
		$this->{workbook}->Save() if $this->{opened} && $needs_save;
		$this->{workbook}->Close() if $this->{opened};
	}
	$this->{workbook} = undef;
	$this->{xl} = undef;
}



#-----------------------------------------------
# ui methods
#-----------------------------------------------

sub startUI
{
	my ($this,$title) = @_;
	$title ||= '';
	display($dbg_book,0,"startUI($this->{bookname},$title)");
	$this->{ui_started} = $this->{xl}->{excel}->
		Run("'$this->{bookname}'!perlStart",$$,$title);
	$this->{ui_started} ?
		display($dbg_book,0,"$this->{bookname} UI started") :
		error("couild not startUI($this->{bookename})");
	return $this->{ui_started};
}




sub endUI
{
	my ($this,$msg,$util_color) = @_;

	$msg ||= 'Done.';
	$util_color ||= $UTILS_COLOR_BLACK;

	display($dbg_book,0,"end_excel($msg,$util_color) any_errors=$this->{any_errors}");

	my $progress_color = $UTILS_COLOR_GREEN;
	my $progress_result = "Finished with no errors";
	if ($this->{any_errors})
	{
		$progress_color = $UTILS_COLOR_RED;
		$progress_result = "Finished with ERRORS !!";
		warning(0,0,"end_excel returning 'ERROR(s)!!");
	}

	$this->progressMsg($progress_result,$progress_color);

	my $rgb = $utils_color_to_rgb->{$util_color};

	$this->{xl}->{excel}->
		Run("'$this->{bookname}'!perlEnd",$msg,$rgb)
			if $this->{ui_started};

	display($dbg_book,0,"endUI($this->{bookname} finished");
}




#---------------------------------------
# display methods
#---------------------------------------

sub setTitle
{
	my ($this,$title) = @_;
	display($dbg_book,0,"setTitle($title)");
	return if !$this->{ui_started};
	$this->{xl}->{excel}->Run("'$this->{bookname}'!setTitle",$title);
}


sub statusMsg
{
	my ($this,$msg,$util_color) = @_;
	$util_color ||= $UTILS_COLOR_BLACK;
	display(0,0,"EXCEL_STATUS: $msg",1,$util_color);
	return if !$this->{ui_started};

	my $rgb = $utils_color_to_rgb->{$util_color};
	# printf "xls_status($util_color,0x%06x,$msg)\n",$rgb;
	$this->{xl}->{excel}->Run("'$this->{bookname}'!perlStatusMsg",$msg,$rgb);
}

sub progressMsg
{
	my ($this,$msg,$util_color) = @_;
	$util_color ||= $UTILS_COLOR_BLACK;
	display(0,0,"EXCEL_PROGRESS(: $msg",1,$util_color);
	return if !$this->{ui_started};

	my $rgb = $utils_color_to_rgb->{$util_color};
	# printf "xls_progress($util_color,0x%06x,$msg)\n",$rgb;
	$this->{xl}->{excel}->Run("'$this->{bookname}'!perlProgressMsg",$msg,$rgb);
}


sub displayXLS
{
	my ($this,$msg,$util_color) = @_;
	$util_color ||= $UTILS_COLOR_BLACK;
	return if !$this->{ui_started};
	my $rgb = $utils_color_to_rgb->{$util_color};
	# printf "xls_display($util_color,0x%06x,$msg)\n",$rgb;
	$this->{xl}->{excel}->Run("'$this->{bookname}'!perlDisplay",$msg,$rgb);
}


sub logMsg
{
	my ($this,$indent,$msg,$call_level) = @_;
	$call_level ||= 0;
	LOG($indent,$msg,$call_level+1);
	$this->displayXLS($msg,$UTILS_COLOR_BLUE);
}

sub displayMsg
{
	my ($this,$level,$indent,$msg,$call_level,$color) = @_;
	$call_level ||= 0;
	$color ||= $UTILS_COLOR_BLACK;
	display($level,$indent,$msg,$call_level+1,$color);
	$this->displayXLS($msg,$color);
}

sub warningMsg
{
	my ($this,$level,$indent,$msg,$call_level) = @_;
	$call_level ||= 0;
	warning($level,$indent,$msg,$call_level+1);
	$this->displayXLS("WARNING: $msg",$UTILS_COLOR_YELLOW);
}


sub errorMsg
{
	my ($this,$msg,$call_level) = @_;
	$call_level ||= 0;
	error($msg,$call_level+1);
	$this->displayXLS("ERROR: $msg",$UTILS_COLOR_RED);
	$this->{any_errors}++;
	return '';
}




1;
