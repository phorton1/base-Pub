#!/usr/bin/perl
#--------------------------------------------------------
# Pub::Excel::xlUtils
#--------------------------------------------------------

package Pub::Excel::xlUtils;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (

		$XLS_JUST_CENTER
		$XLS_JUST_LEFT
		$XLS_JUST_RIGHT

		xlsGetValue
		xlsGetFormula
		xlsGetHyperlink

		xlsSetValue
		xlsSetNumberFormat
		xlsSetJustification
		xlsSetFillColor
		xlsSetTextColor
		xlsSetBold
		xlsSetFormula

		xlrc
		utilToBgrColor

		xlsRowToHash
		xlsHashToRow
	);
};


#---------------------------------
# sheet accessors
#---------------------------------

sub xlsGetValue
{
    my ($sheet,$row,$col) = @_;
    my $val = $sheet->Cells($row, $col)->{Value};
	$val = '' if !defined($val);
	$val =~ s/\s+$//g;
	$val =~ s/^\s+//g;
	return $val;
}


sub xlsGetFormula
	# only returns anything if the 'Formula' starts with an equals sign,
	# as Excel will return the value in lieu of an actual formula.
{
    my ($sheet,$row,$col) = @_;
    my $formula = $sheet->Cells($row, $col)->{Formula};
	$formula = '' if !defined($formula) || $formula !~ /^=/;
	return $formula;
}


sub xlsGetHyperlink
	# returns the Hyperlink object if one exists.
	# Client may use $link->{Address} to see the link,
	# or any of the other properties on the link.
	# See https://learn.microsoft.com/en-us/office/vba/api/excel.hyperlink
	# also for the methods, including "Delete()" to remove the link.
{
    my ($sheet,$row,$col) = @_;
    my $link = '';
	my $links = $sheet->Cells($row, $col)->{Hyperlinks};
	$link = $links->Item(1) if $links && $links->{Count};
	return $link;
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
	# Interior->{color} takes a BGR_COLOR
{
    my ($sheet,$row,$col,$util_color) = @_;
    $sheet->Cells($row, $col)->{Interior}->{color} = utilToBgrColor($util_color);
}


sub xlsSetTextColor
	# Font->{color} takes a BGR_COLOR
	# Could also use an XLS_COLOR index with Font->{ColorIndex}
{
    my ($sheet,$row,$col,$util_color) = @_;
    $sheet->Cells($row, $col)->{Font}->{color} = utilToBgrColor($util_color);
}


sub xlsSetBold
{
    my ($sheet,$row,$col,$bold) = @_;
    $sheet->Cells($row, $col)->{Font}->{Bold} = $bold ? 1 : 0;
}


sub xlsSetFormula
{
    my ($sheet,$row,$col,$formula) = @_;
	$sheet->Cells($row, $col)->{Formula} = $formula;
}



#---------------------------------
# general utilties
#---------------------------------

sub xlrc
{
    my ($row,$col) = @_;
	my $rc = ('A'..'Z')[$col-1].$row;
	return $rc;
}


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



#---------------------------------
# hash utilties
#---------------------------------

sub xlsRowToHash
	# gets a row of an excel table into a hash record
	# given a densly populated header row ...
{
	my ($sheet,$header_row,$row) = @_;
	my $rec = {};
	my $col = 1;
	my $field = xlsGetValue($sheet,$header_row,$col);
	while ($field)
	{
		$rec->{$field} = xlsGetValue($sheet,$row,$col) || '';
		$col++;
		$field = xlsGetValue($sheet,$header_row,$col);
	}
	return $rec;
}


sub xlsHashToRow
	# converts a hash to an excel row when the hash keys
	# match the excel header_row field names.
{
	my ($sheet,$header_row,$row,$rec) = @_;

	my $col = 1;
	my $field = xlsGetValue($sheet,$header_row,$col);
	while ($field)
	{
		my $val = $rec->{$field};
		$val = '' if !defined($val);
		$val =~ /^=/ ?
			xlsSetFormula($sheet,$row,$col,$val) :
			xlsSetValue($sheet,$row,$col,$val);
		$col++;
		$field = xlsGetValue($sheet,$header_row,$col);
	}
}


1;
