#!/usr/bin/perl

#------------------------------------------
# Pub::WX::Dialogs
#------------------------------------------
# CR should be OK

package Pub::WX::Dialogs;
use strict;
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::Event qw(EVT_BUTTON);
use Pub::Utils;
use base qw( Wx::Dialog );


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (
        okDialog
        yesNoAllDialog
		yesNoDialog
		yesNoCancelDialog
	);
}


my $ID_ALL_BUTTON = 12395;



sub okDialog
{
	my ($win,$msg,$title) = @_;
    $win = getAppFrame() if (!$win);
	my $this =  Wx::MessageDialog->new($win,$msg,$title,wxOK);
    my $rslt = $this->ShowModal();
    $this->Destroy();
    return 1;
}


sub yesNoDialog
	# cannot currently set default,
	# which is dangerous
{
	my ($win,$msg,$title) = @_;
    $win = getAppFrame() if (!$win);
	my $this =  Wx::MessageDialog->new($win,$msg,$title,wxYES|wxNO|wxCENTRE);
    my $rslt = $this->ShowModal();
    $this->Destroy();
    return ($rslt == wxID_YES) ? 1 : 0;
}


sub yesNoCancelDialog
	# cannot currently set default,
	# which is dangerous
{
	my ($win,$msg,$title,$default) = @_;
    $win = getAppFrame() if (!$win);
    my $this =  Wx::MessageDialog->new($win,$msg,$title,wxYES|wxNO|wxCANCEL|wxCENTRE);
    my $rslt = $this->ShowModal();
    $this->Destroy();
	return
		($rslt == wxID_YES) ? 1 :
		($rslt == wxID_NO)  ? 0 :
		-1;
}


sub yesNoAllDialog
	# Does not include All if $count == 0
{
	my ($win,$count,$msg,$title,$default) = @_;
    $win = getAppFrame() if (!$win);
    my $class = __PACKAGE__;
	my $this = $class->SUPER::new($win,-1,$title,[-1,-1],[463,190],wxDEFAULT_DIALOG_STYLE);
	display(5,0,"yesNoAllDialog(count=$count,class=$class this=$this");

	# create message 'pane'

	my $inner_win = Wx::Window->new($this,-1,[0,0],[460,112]);
	$inner_win->SetBackgroundColour(wxWHITE);
	Wx::StaticText->new($inner_win,-1,$msg,[65,26]);

	# sheesh - it was hard to get an icon to display

	my $app_frame = getAppFrame();
	my $icon = $app_frame->{app}->GetStdIcon(wxICON_QUESTION);
	display(5,0,"got icon=$icon");
	my $bitmap = Wx::Bitmap->new(32,32,8);
	$bitmap->CopyFromIcon($icon);
	Wx::StaticBitmap->new($inner_win,-1,$bitmap,[25,25]);

	# create buttons
	# count includes current file

	Wx::Button->new($this,$ID_ALL_BUTTON,"Yes to All (".($count+1).")",[134,124],[110,25])
		if ($count);
	Wx::Button->new($this,wxID_YES,"&Yes",[264,124],[85,25]);
	Wx::Button->new($this,wxID_NO,"&No",[361,124],[85,25]);

	# set defaults

	$this->SetEscapeId(wxID_NO);
	$default ||= wxID_YES;
	my $default_button = $this->FindWindow($default);
	$default_button->SetFocus() if ($default_button);

	EVT_BUTTON($this,-1,\&onButton);

    my $rslt = $this->ShowModal();
    $this->Destroy();
    return
		($rslt == $ID_ALL_BUTTON) ? -1 :
		($rslt == wxID_YES) ? 1 : 0;
}


sub onButton
{
	my ($this,$event) = @_;
	$this->EndModal($event->GetId());
}


#-------------------------------------------------
# DialogToast
#-------------------------------------------------


package Pub::WX::DialogToast;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::Event qw(EVT_IDLE);
use base qw(Wx::Dialog);


sub doToast
{
    my ($class,$title,$msg,$time) = @_;

	my $this = $class->SUPER::new(undef,-1,$title,[-1,-1],[500,120]);

 	Wx::StaticText->new($this,-1,"",[0,0]);
		# weirdness ... wx does not layout a single control correctly
		# so I have to include this dummy one
	Wx::StaticText->new($this,-1,$msg,[20,10],[460,60],wxALIGN_CENTRE_HORIZONTAL);

	$time ||= 5;
	$this->{time} = $time;
	$this->{started} = time();

	EVT_IDLE($this,\&onIdle);
    $this->Show();
}


sub onIdle
{
	my ($this,$event) = @_;
	$event->RequestMore();
	$this->Close() if time() > $this->{started} + $this->{time};
}



#--------------------------------------------------
# progressDialog
#--------------------------------------------------

package Pub::WX::ProgressDialog;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::Event qw(
	EVT_CLOSE
	EVT_BUTTON
	EVT_IDLE );
use Pub::Utils;
use base qw(Wx::Dialog);


my $ID_CANCEL = 4567;

my $_active;
my $_dialog_active :shared = 0;
my $_force_close   :shared = 0;

sub isActive        { return defined $_active ? 1 : 0; }
sub isActiveShared  { return $_dialog_active }
sub setForceClose   { $_force_close = 1 }
sub forceCloseActive
{
	return unless $_force_close && defined $_active;
	$_force_close = 0;
	$_active->Destroy();
}


sub newProgressData
	# Creates the shared progress data object passed to both new() and API command hashes.
	# Set {active}=1 before queuing commands; the consumer reads and updates it.
	# $workers: number of independent services contributing (default: undef = single-service
	# mode where completion is detected by done >= total).  With $workers, each service
	# decrements {workers} when its batch is done; dialog closes when {workers} hits 0.
{
	my ($total, $workers) = @_;
	my $data = &threads::shared::share({});
	$data->{active}    = 0;
	$data->{total}     = ($total // 0) + 0;
	$data->{done}      = 0;
	$data->{cancelled} = 0;
	$data->{error}     = '';
	$data->{label}     = '';
	$data->{workers}   = ($workers + 0) if defined $workers;
	return $data;
}


sub new
{
	my ($class, $parent, $title, $w_cancel, $range_or_data, $msg) = @_;
	$msg ||= '';

	# $range_or_data: number (old-style range) or shared hashref from newProgressData (new-style)
	my ($progress_data, $range);
	if (ref($range_or_data) eq 'HASH')
	{
		$progress_data = $range_or_data;
		$range     = $progress_data->{total} || 1;
	}
	else
	{
		$range = $range_or_data || 1;
	}

	$parent = getAppFrame() if !$parent;
	$parent->Enable(0) if $parent;

	my $this = $class->SUPER::new($parent,-1,$title,[-1,-1],[300,120 + ($w_cancel?40:0)]);

	$this->{parent}    = $parent;
	$this->{title}     = $title;
	$this->{w_cancel}  = $w_cancel;
	$this->{range}     = $range;
	$this->{msg}       = $msg;
	$this->{done}      = 0;
	$this->{cancelled} = 0;
	$this->{terminal}  = 0;
	$this->{progress_data} = $progress_data;

	$this->{msg_ctrl} = Wx::StaticText->new($this,-1,$msg,[20,10]);
	$this->{gauge}    = Wx::Gauge->new($this,-1,$range,[20,50],[255,16]);

	if ($w_cancel)
	{
		my $lbl = ($progress_data && $progress_data->{cancel_label}) ? $progress_data->{cancel_label} : 'Cancel';
		$this->{cancel_btn} = Wx::Button->new($this,$ID_CANCEL,$lbl,[200,80],[60,20]);
		EVT_BUTTON($this,$ID_CANCEL,\&onCancel);
	}
	EVT_CLOSE($this,\&onCloseProgressDialog);
	EVT_IDLE($this,\&_onIdle) if $progress_data;

	$this->Show();
	display(-1, 0, "===== ProgressDialog '$title' STARTED =====", 0, $UTILS_COLOR_LIGHT_MAGENTA);
	Wx::App::GetInstance()->Yield();
	$_active = $this;
	$_dialog_active = 1;
	return $this;
}


sub Destroy
{
	my ($this) = @_;
	$_active = undef;
	$_dialog_active = 0;
	display(-1, 0, "===== ProgressDialog '$this->{title}' FINISHED =====", 0, $UTILS_COLOR_LIGHT_MAGENTA);
	if ($this->{parent})
	{
		$this->{parent}->Enable(1);
	}
	$this->SUPER::Destroy();
}


sub update
{
    my ($this,$inc,$msg) = @_;
	# Pub::Utils::display(0,0,"update($inc,$this->{done}/$this->{range})");
	$this->set($this->{done} + $inc, $msg);
}


sub set
{
	my ($this,$done,$msg) = @_;
	my $refresh = 0;

	if (defined($msg) && $msg ne $this->{msg})
	{
		$refresh = 1;
		$this->{msg} = $msg;
	    $this->{msg_ctrl}->SetLabel($msg);
	}

	if ($done != $this->{done})
	{
		$refresh = 1;
		$this->{done} = $done;
		$this->{gauge}->SetValue($this->{done});;
	}

	if ($refresh)
	{
		$this->Refresh();
		Wx::App::GetInstance()->Yield();
	}

    return $this->{cancelled} ? 0 : 1;
}


sub cancelled
{
    my ($this) = @_;
    return $this->{cancelled} ? 1 : 0;
}



sub _onIdle
{
	my ($this, $event) = @_;
	my $data = $this->{progress_data};
	return unless $data && $data->{active};

	if ($data->{error})
	{
		$this->setTerminal($data->{error});
		return;
	}
	if ($data->{cancelled})
	{
		$this->setTerminal($data->{cancel_msg} // 'Cancelled by user');
		return;
	}

	my $total   = $data->{total}   + 0;
	my $done    = $data->{done}    + 0;
	my $workers = exists($data->{workers}) ? $data->{workers} + 0 : undef;

	# Re-range gauge when total has grown since dialog was created
	if ($total > 0 && $total != $this->{range})
	{
		$this->{range} = $total;
		$this->{gauge}->SetRange($total);
	}

	# Completion: all workers finished (multi-service), or progress complete (single-service)
	my $done_flag =
		(defined $workers && $workers == 0) ||
		(!defined $workers && $total > 0 && $done >= $total);
	if ($done_flag)
	{
		$data->{active} = 0;
		$this->Destroy();
		return;
	}

	my $label = $data->{label} // '';
	if ($total == 0)
	{
		$this->{gauge}->Pulse();
		my $msg = $label || 'Starting...';
		if ($msg ne ($this->{msg} // ''))
		{
			$this->{msg} = $msg;
			$this->{msg_ctrl}->SetLabel($msg);
			$this->Refresh();
		}
	}
	else
	{
		my $msg = $label ? "$label ($done/$total)" : "$done / $total";
		$this->set($done, $msg);
	}
	$event->RequestMore(1);
}


sub setTerminal
	# Transition dialog to terminal (error/cancel) state: red message, Close button, allow close.
	# Frame remains disabled until user explicitly closes the dialog.
{
	my ($this, $msg) = @_;
	return if $this->{terminal};
	$this->{terminal}          = 1;
	$this->{progress_data}{active} = 0 if $this->{progress_data};
	$this->{msg_ctrl}->SetForegroundColour(Wx::Colour->new(180, 0, 0));
	$this->{msg_ctrl}->SetLabel($msg);
	my $btn = $this->{cancel_btn};
	$btn->SetLabel('Close') if $btn;
	$this->Refresh();
	Wx::App::GetInstance()->Yield();
}

sub onCloseProgressDialog
{
	my ($this,$event) = @_;
	if ($this->{terminal})
	{
		$this->Destroy();
	}
	else
	{
		$event->Veto();
	}
}


sub onCancel
{
	my ($this,$event) = @_;
	if ($this->{terminal})
	{
		$this->Destroy();
	}
	elsif ($this->{progress_data})
	{
		$this->{progress_data}{cancelled} = 1;
	}
	else
	{
		$this->{cancelled} = 1;
		$event->Skip();
	}
}


sub setRange
{
	my ($this,$range,$done,$msg) = @_;
	$this->{gauge}->SetRange($range);
	$this->set($done,$msg);
}





1;
