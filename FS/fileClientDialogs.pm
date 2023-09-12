#!/usr/bin/perl
#-------------------------------------------------
# mkdirDialog
#-------------------------------------------------

package Pub::FS::mkdirDialog;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw(EVT_BUTTON);
use Pub::Utils;
use base qw(Wx::Dialog);


sub new
{
    my ($class,$parent) = @_;
	my $this = $class->SUPER::new(
        $parent,-1,"Create Directory",
        [-1,-1],
        [360,120],
        wxDEFAULT_DIALOG_STYLE | wxRESIZE_BORDER);

    my $i = 1;
    my $hash = $parent->{hash};
    my $default = 'New folder';
    while ($$hash{$default})
    {
        $default = "New folder (".($i++).")";
    }

    Wx::StaticText->new($this,-1,'New Folder:',[10,12]);
    $this->{newname} = Wx::TextCtrl->new($this,-1,$default,[80,10],[255,20]);
    Wx::Button->new($this,wxID_OK,'OK',[60,45],[60,20]);
    Wx::Button->new($this,wxID_CANCEL,'Cancel',[220,45],[60,20]);
    EVT_BUTTON($this,-1,\&onButton);
    return $this;
}


sub getResults
{
    my ($this) = @_;
    my $rslt = $this->{newname}->GetValue();
    $rslt =~ s/\s*//;
    return $rslt;
}


sub onButton
{
    my ($this,$event) = @_;
    my $id = $event->GetId();
    if ($id == wxID_OK)
    {
        my $val = $this->getResults();
        $val =~ s/\s*//;
        return if !$val;

        if ($val =~ /\\|\/|:/ ||
            $val eq '.' || $val eq '..')
        {
            error("Illegal folder name: $val");
            return;
        }

        my $hash = $this->GetParent()->{hash};

        if (0)
		{
			display(0,1,"parent->hash=$hash");
			for my $k (sort(keys(%$hash)))
			{
				display(0,2,$k);
			}
		}

        if ($$hash{$val})
        {
            error("A folder/file of this name already exists: $val");
            return;
        }
    }

    $event->Skip();
    $this->EndModal($id);
}



1;
