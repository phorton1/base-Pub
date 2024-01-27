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
use Pub::SQLite;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (

		$XLS_JUST_CENTER
		$XLS_JUST_LEFT
		$XLS_JUST_RIGHT

		xlsGetValue
		xlsSetValue
		xlsSetNumberFormat
		xlsSetJustification
		xlsSetFillColor
		xlsSetTextColor
		xlsSetBold
		xlsSetFormula

		xlrc
		utilToBgrColor

		xlsRecToDbRec
		xlsDBFieldCols
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
	my $rc = xlrc($row,$col);
	# display(0,0,"row($row,$col) range($rc)");
	$sheet->Range($rc)->{Formula} = $formula;
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
# database utilties
#---------------------------------

sub xlsRecToDbRec
{
	my ($table,$sheet,$row) = @_;

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




1;
