#!/usr/bin/perl
#-------------------------------------------------
# mkdirDialog
#-------------------------------------------------

package mkdirDialog;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw(EVT_BUTTON EVT_TEXT_ENTER);	# EVT_CHAR);
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
    $this->{newname} = Wx::TextCtrl->new($this,-1,$default,[80,10],[255,20],wxTE_PROCESS_ENTER);
    Wx::Button->new($this,wxID_CANCEL,'Cancel',[220,45],[60,20]);
		# responds to ESC in any case
    my $ok_button = Wx::Button->new($this,wxID_OK,'OK',[60,45],[60,20]);
	$ok_button->SetDefault();
		# highlights the button as if ENTER is same as OK
		# but really the text ctrl has the focus, so we have to
		# specify wxTE_PROCESS_ENTER and handle the EVT_TEXT_ENTER
		# to get it work right.  If they tab around to the button
		# again, and then hit enter it *would* work.

	EVT_TEXT_ENTER($this,-1,\&onEnter);
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


sub setResults
{
    my ($this) = @_;

	my $val = $this->getResults();
	$val =~ s/\s*//;
	return 0 if !$val;

	if ($val =~ /\\|\/|:/ ||
		$val eq '.' || $val eq '..')
	{
		error("Illegal folder name: $val");
		return 0;
	}

	my $hash = $this->GetParent()->{hash};
	if ($hash->{$val})
	{
		error("A folder/file of this name already exists: $val");
		return 0;
	}

	return 1;
}




# sub onChar
# {
#     my ($this,$event) = @_;
# 	my $char = $event->GetKeyCode();
#     if ($char == 13)
# 	{
# 		return if !$this->setResults();
# 	    $event->Skip();
# 		$this->EndModal(wxID_OK)
# 	}
# 	if ($char == 27)
# 	{
# 	    $event->Skip();
# 		$this->EndModal(wxID_CANCEL)
# 	}
# }


sub onEnter
{
	my ($this,$event)= @_;
    $this->EndModal(wxID_OK) if $this->setResults();
}



sub onButton
{
    my ($this,$event) = @_;
    my $id = $event->GetId();
	return if $id == wxID_OK && !$this->setResults();
    $event->Skip();
    $this->EndModal($id);
}



1;
