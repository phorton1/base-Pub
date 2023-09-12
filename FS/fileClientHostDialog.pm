#!/usr/bin/perl
#-------------------------------------------------
# fileClientHostDialog
#-------------------------------------------------

package Pub::FS::fileClientHostDialog;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw(EVT_BUTTON);
use Pub::Utils;
use base qw(Wx::Dialog);


our $dbg_fch = 1;

my $info_file = "/base/apps/file2/file_hosts.txt";


#-------------------------------------
# info file
#-------------------------------------

sub strip_blanks
{
	my ($text) = @_;
	$text =~ s/^\s+//;
	$text =~ s/\s+$//;
	return $text;
}



sub getConnectInfo
{
	my ($name) = @_;
	my $infos = readConnectInfo();
	return if !$infos;
	for my $info (@$infos)
	{
		return $info if $info->{NAME} eq $name;
	}
	error("Could not find connectInfo($name)");
}


sub readConnectInfo
{
	display($dbg_fch,0,"readConnectInfo");
	my $text = getTextFile($info_file);
	my $info;
	my $infos = [];
	my $line_num = 0;
	for my $line (split(/\n/,$text))
	{
		$line_num++;
		$line =~ s/#.*$//;
		$line = strip_blanks($line);
		next if !$line;

		if ($line !~ /^(.*)=(.*)$/ || !$1 || !$2)
		{
			error("Syntax error in $info_file($line_num): $line");
			return;
		}
		my ($lval,$rval) = ($1,$2);
		$lval = uc(strip_blanks($lval));
		$rval = strip_blanks($rval);
		if ($lval eq 'NAME')
		{
			display($dbg_fch,1,"new info($rval)");
			$info = {
				NAME => $rval,
				HOST => '',
				PORT => '',
				SLAVE => '',
				LOCAL_DIR => '',
				REMOTE_DIR => '' };

			push @$infos,$info;
		}
		elsif ($lval =~ /^(HOST|PORT|SLAVE|LOCAL_DIR|REMOTE_DIR)$/)
		{
			if (!$info)
			{
				error("$lval specified before NAME at $info_file($line_num)");
				return;
			}
			display($dbg_fch,2,"$lval = $rval");
			$info->{$lval} = $rval;
		}
		else
		{
			error("unknown paramater($lval) at $info_file($line_num): $line");
		}
	}
	display($dbg_fch,0,"readConnectInfo() returning ".scalar(@$infos)." info records");
	return $infos;
}



#-------------------------------------
# dialog
#-------------------------------------


sub selectConnectInfo
{
    my ($class,$parent) = @_;
	display($dbg_fch,0,"fileClientHostDialog::selectConnectInfo()");
	my $infos = readConnectInfo();
	if (!$infos || !@$infos)
	{
		error("No info found in $info_file");
		return;
	}

	my $this = $class->SUPER::new(
        $parent,
		-1,
		"Select Host to Connect To",
        [-1,-1],
        [900,800],
        wxDEFAULT_DIALOG_STYLE | wxRESIZE_BORDER);

	my $id = 0;
	my $yoff = 10;
	for my $info (@$infos)
	{
	    Wx::Button->new($this,$id++,$info->{NAME},[10,$yoff],[150,30]);

		my $text = '';
		for my $field (qw(NAME HOST PORT LOCAL_DIR REMOTE_DIR))
		{
			my $val = $info->{$field};
			$text .= "$field($val)  " if $val;
		}

	    Wx::StaticText->new($this,-1,$text,[175,$yoff+8]);

		$yoff += 40;
	}

    # Wx::Button->new($this,wxID_CANCEL,'Cancel',[10,$yoff],[60,20]);
    EVT_BUTTON($this,-1,\&onButton);
    my $rslt = $this->ShowModal();
	return '' if $rslt == wxID_CANCEL;

	display($dbg_fch,0,"fileClientHostDialog::selectConnectInfo() returning $infos->[$rslt]->{NAME}");
	return $infos->[$rslt]->{NAME};
}




sub onButton
{
    my ($this,$event) = @_;
    my $id = $event->GetId();
    $event->Skip();
    $this->EndModal($id);
}


1;
