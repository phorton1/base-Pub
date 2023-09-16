#!/usr/bin/perl
#---------------------------------------------------------------------

package Pub::WX::Frame;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw(
    EVT_MENU
    EVT_UPDATE_UI
    EVT_COMMAND );
use Pub::Utils;
use Pub::WX::Resources;
use Pub::WX::AppConfig;
use Pub::WX::FrameBase;
use Pub::WX::Notebook;
use Pub::WX::Menu;
use Pub::WX::Dialogs;
use base qw(Wx::Frame Pub::WX::FrameBase);


our $dbg_frame = 2;
    # debug Pub::WX::Frame - lower means more
our $dbg_sr = 2;
    # debug save & restore of config state


#---------------------------------------------------
# Known WX debugging constants
#--------------------------------------------------
#
# You can set the global debug level via PRH_WX_DEBUG environment variable.
#    It defaults to 0
# You can set groups of functions debug levels via environment variables
#    PRH_WX_DEBUG_DD = 0
# The messages go to STDOUT, formatted to look somewhat like
#    those from appUtils::display(). They do NOT go to the
#    appUtils logfile.
#
# Set PRH_WX_DEBUG = 0       global debugging level or
# Set PRH_WX_DEBUG_DD = 2    dbg_dd debug level (default = 5)
#
# Probably want to figure out backtrace and stack indentation
#
#    dbg_dd  		"DD"     	drag and drop debugging flag
#    dbg_ddd 		"DDD"    	drag and drop details flag
#    dbg_sl  		"SL"     	save/load perspective
#    dbg_sld 		"SLD"    	save/load perspective details
#    dbg_rs 		"_RS"     	richTextBuffer styling
#    dbg_rsd 		"_RSD"   	richTextBuffer details
#    dbg_rsdd 		"_RSDD" 	richTextBuffer gruesome details
#    dbg_rsp  		"_RSP"  	debug paragraph pasting
#    dbg_undo  		"_UNDO"  	richTextBuffer/stc "undo" scheme
#    dbg_undod 		"_UNDOD" 	richTextBuffer/stc "undo" scheme details
#    dbg_print 		"PRINT"  	html easy printing, etc


sub CLONE_SKIP { 1 };
	# putting this in a package prevents it from being
	# cloned when the perl interpreter is copied to a new
	# thread, so that, also, the DESTROY methods are not
	# called on the bogus memory object.  This should be
	# in all WxWidgets objects, which should not be
	# touchable, except by the main thread, and all
	# threads should only work on a small set of
	# well known variables, mostly shared.


#--------------------------------------------
# Construct, Init, Close, and Destroy
#--------------------------------------------

sub new
{
	my ($class, $parent) = @_;

	# has to go somewhere

	Wx::InitAllImageHandlers();

	# get a useable windows size to start
    # and note if we've run before

	Pub::WX::AppConfig::initialize();

    my $config_rect = readConfigRect("window_rect");
	my $config_exists = $config_rect ? 1 : 0;
    display($dbg_frame,2,"config_exists=$config_exists");
	$config_rect = Wx::Rect->new(200,100,900,600) if (!$config_rect);
    writeConfigRect("window_rect",$config_rect);
    writeConfig("running",1);
    Pub::WX::AppConfig::save();

    # create super class, populate, and inherit

    my $title = $$resources{app_title};
	my $this = $class->SUPER::new( $parent, -1, $title,
        [ $config_rect->x, $config_rect->y ],
        [ $config_rect->width, $config_rect->height ] );

    $this->{config_exists} = $config_exists;
    $this->{dont_auto_open} = {};

    # become the main application frame and return

    setAppFrame($this);
    return $this->FrameBase($this);

}   # Pub::WX::Frame::new()



sub onInit
{
    my ($this) = @_;
    display($dbg_frame,0,"Pub::WX::Frame::onInit");

	$this->{frames}  = {};
    $this->{panes}   = [];
	$this->{notebooks} = {};
	warning($dbg_frame,0,"$this initial frames=$this->{frames}");

    # add notebook commands to the view menu if the client desires

    my $got_one = 0;
    my @nb_command_ids;
    for my $nb (@{$resources->{notebooks}})
    {
        my $command_id = $$nb{command_id};
        if ($command_id)
        {
            push @{$resources->{view_menu}},$ID_SEPARATOR
                if (!$got_one);
            $got_one = 1;
            push @{$resources->{view_menu}},$command_id;
            EVT_MENU($this, $command_id, \&onOpenNotebook);
        }
    }

    # restore the state from the ini file if it exists
    # or, if not, create the default setup and save it ...

    if (!$this->{config_exists} ||
		!$this->restore_state())
	{
        my @nb_command_ids;
        for my $nb (@{$resources->{notebooks}})
        {
            my $bname = $nb->{name};
            $this->{notebooks}->{$bname} = Pub::WX::Notebook->new($this,$bname);
            $this->{notebooks}->{$bname}->closeSelf() if ($bname ne 'content');
        }
        $this->save_state();
    }

    # create the system menu

	$this->setMainMenu();

    # register event handlers

	EVT_MENU($this, $CLOSE_ALL_PANES, \&onCloseWindows);
	EVT_MENU($this, $CLOSE_OTHER_PANES, \&onCloseWindows);
    EVT_UPDATE_UI($this, $CLOSE_ALL_PANES, \&onCloseWindowsUI);
	EVT_UPDATE_UI($this, $CLOSE_OTHER_PANES, \&onCloseWindowsUI);

    # finished

	$this->{running} = 1;
    return $this;

}   # Pub::WX::Frame::onInit()



sub addFloatingFrame
{
	my ($this,$instance,$frame) = @_;
	warning($dbg_frame,0,"$this $this->{frames} addFloatingFrame($instance)=$frame");
	$this->{frames}->{$instance} = $frame;
}

sub deleteFloatingFrame
{
	my ($this,$instance) = @_;
	warning($dbg_frame,0,"$this $this->{frames} deleteFloatingFrame($instance)="._def($this->{frames}->{$instance}));
	delete $this->{frames}->{$instance};
	warning($dbg_frame,0,"after delete $this->{frames}");
}



sub DESTROY
{
	my ($this) = @_;
	display($dbg_frame,0,"DESTROY Pub::WX::Frame");
	setAppFrame(undef);

	# bypassing months of work years ago, I now just bail on
	# any memory management and return short here ..
	return;

	$this->Pub::WX::FrameBase::DESTROY();

	delete $this->{current_pane};

	if ($this->{panes})
	{
		for my $pane (@{$this->{panes}})
		{
			$pane->DESTROY();
		}
		delete $this->{panes};
	}

	if ($this->{notebooks})
	{
		for my $notebook (values %{$this->{notebooks}})
		{
			$notebook->DESTROY();
		}
		delete $this->{notebooks};
	}

	if ($this->{frames})
	{
		for my $frame (values %{$this->{frames}})
		{
			$frame->DESTROY();
		}
		delete $this->{frames};
	}

	display($dbg_frame,0,"finished Pub::WX::Frame::DESTROY()");
}


sub onCloseFrame
	# save the state of the windows and frames.
	# clear the running flag to indicate we are shutting down,
	# close the windows, and if anybody objects reset the flag
	# returns 0 if anybody objected, 1 if everybody was closed
{
	my ($this,$event) = @_;
	display($dbg_frame,0,"start Pub::WX::Frame::onCloseFrame()");

	$this->save_state();

	$this->{running} = 0;
	my $rslt = $this->onCloseWindows($event);
	display($dbg_frame,0,"end Pub::WX::Frame::onCloseFrame() rslt="._def($rslt));

	if (!$rslt)
	{
		$this->{running} = 1;
		$event->Veto();
	}
	else
	{
		$event->Skip();
	}
    return $rslt;
}


#------------------------------------------------------------
# create the main menu
#------------------------------------------------------------


sub setMainMenu

{
	my ($this) = @_;
	display($dbg_frame,1,"setMainMenu()");

    my $menu_items = $resources->{main_menu};
    my $menubar= Wx::MenuBar->new();
	display($dbg_frame,2,"found ".scalar(@$menu_items)." menu items");

	foreach my $menu_title (@$menu_items)
	{
		my ($menu_name,$menu_title) = split(/,/,$menu_title);
		display($dbg_frame+1,2,"menu_item($menu_name,$menu_title)");
		my $menu = Pub::WX::Menu::createMenu($menu_name);
		$menubar->Append($menu,$menu_title);
	}
	$this->SetMenuBar($menubar);
}




#------------------------------------------------------------
# Save and Restore window state
#------------------------------------------------------------


sub display_rect
{
	my ($dbg,$level,$msg,$rect) = @_;
	display($dbg,$level,$msg."(".
		$rect->x.",".
        $rect->y.",".
		$rect->width.",".
        $rect->height.")",1);
}


sub save_state
{
    my ($this) = @_;
	return if !$Pub::WX::AppConfig::ini_file;
    display($dbg_sr,0,"start Pub::WX::Frame::save_state($this)");

	# save the window position to the config file

	my $main_rect = $this->GetScreenRect();
	display_rect($dbg_sr,1,"Saving main Window Rect",$main_rect);
	writeConfigRect("window_rect",$main_rect);

	# get the perspective

	my $perspective = $this->{manager}->SavePerspective();
	display($dbg_sr,1,"writing $this perspective='$perspective'");
	writeConfig("perspective",$perspective);

	# write the main notebooks

	foreach my $bname (keys(%{$this->{notebooks}}))
	{
		my $book = $this->{notebooks}->{$bname};
        if ($book)
        {
            display($dbg_sr,2,"saving $this notebook($bname)");
            my $str = $book->getConfigStr();
            display($dbg_sr,2,"writing $bname"."_panes='$str'");
    		writeConfig($bname."_panes",$str);
        }
	}

	# write the floating notebooks (frames)
	# which each have a single {book} member

	my $fnum = 0;
	warning($dbg_sr,0,"saving frames $this $this->{frames} num=".scalar(keys %{$this->{frames}}));
	foreach my $frame_id (sort keys %{$this->{frames}})
	{
		my $frame = $this->{frames}->{$frame_id};
		my $book = $frame->{book};
		next if (!$book);

        display($dbg_sr,1,"saving $frame($frame_id) notebook($book->{name})");

		$fnum++;
		my $config_id = "/frame$fnum";

		my $str = $book->getConfigStr();
		display($dbg_sr,2,"writing $config_id/content_panes='$str'");
		writeConfig("$config_id/content_panes",$str);

		my $frame_perspective = $frame->{manager}->SavePerspective();
		display($dbg_sr,2,"writing $config_id/perspective='$frame_perspective'");
		writeConfig("$config_id/perspective",$frame_perspective);

		my $rect = $frame->GetScreenRect();
		display_rect($dbg_sr,2,"writing $config_id/window_rect=",$rect);
		writeConfigRect("$config_id/window_rect",$rect);
	}

	# clean out any following elements
	# cleaning out ini sections should be done right

	$fnum++;
	while (configHasGroup("/frame$fnum"))
	{
		display($dbg_sr,0,"deleting frame configuration /frame$fnum");
		configDeleteGroup("/frame$fnum");
		$fnum++;
	}

	# turn off the running bit, and save the file

	writeConfig("running","0");
	Pub::WX::AppConfig::save();
    display($dbg_sr,0,"finish Pub::WX::Frame::save_state()");

}   # Pub::WX::Frame::save_state()



sub restore_state
    # load any tools (and/or files) into the main notebooks
    # open up any needed floating frames
{
    my ($this) = @_;
	return if !$Pub::WX::AppConfig::ini_file;
    display($dbg_sr,0,"start Pub::WX::Frame::restore_state()");
    my $main_perspective = readConfig("perspective");

    my $num_found = 0;
    while (my $bname = ($main_perspective =~ s/\|name=(.*?);// ? $1 : undef))
    {
        $num_found++;
        display($dbg_sr,0,"restoring main notebook($bname)");

        # pull out | delimited elements as written in
        # Pub::WX::Notebook::getConfigStr()

        my $book = $this->getOpenNotebook($bname);
        my $str = readConfig($bname."_panes");
        display($dbg_sr,1,"got $bname"."_panes='$str'");

        my @parts = split(/\|/,$str);
        my $pers = shift(@parts) || '';
        display($dbg_sr,1,"$bname starting nb pers=$pers");

        my $id = shift(@parts);
        while ($id)
        {
			my $orig_id = $id;
			my $instance = shift(@parts) || 0;
			$id -= $instance;
				# Subtract out the instance on restore, and we have
				# fix the perspective to use the next available instance
				# from the object below

            my $data = shift(@parts) || '';
            my $config_str = shift(@parts) || '';
            display($dbg_sr,2,"window($id) data='$data' str='$config_str'");
			my $pane = $this->createPane($id,$book,$data,$config_str);

			# this RE is moderately dangerous inasmuch as there *could*
			# be other unexpected strings of the form (,|*)12123(,|;)

			my $new_id = $pane->{id};
			$pers =~ s/(,|\*)$orig_id(,|;)/$1$new_id$2/g if $instance && $pers;

			$id = shift(@parts);
        }

        display($dbg_sr,1,"$bname loading final nb pers=$pers");
        $book->LoadPerspective($pers) if $pers;
    }

    if (!$num_found)
    {
        error("bad INI file - using default configuration");
        return 0;
    }

    # for floating notebooks as well as standard tools in
    # external panes, we create the floating frame ..

    my $fnum=1;
    my $config_id = "/frame$fnum";
    while (my $str = readConfig("$config_id/content_panes"))
    {
        display($dbg_sr,0,"restoring floating /frame$fnum='$str'");

        my $frame_rect = readConfigRect("$config_id/window_rect");
		display_rect($dbg_sr,1,"got rect",$frame_rect) if $frame_rect;
        $frame_rect = Wx::Rect->new(50,100,500,400) if !$frame_rect;

        my @parts = split(/\|/,$str);
        my $pers = shift(@parts) || '';

        display($dbg_sr,1,"starting nb pers='$pers'");

        my $frame;
        my $id = shift(@parts);
        while ($id)
        {
			my $orig_id = $id;
			my $instance = shift(@parts) || 0;
			$id -= $instance;
				# Subtract out the instance on restore, and we have
				# fix the perspective to use the next available instance
				# from the object below

            my $data = shift(@parts) || '';
            my $config_str = shift(@parts) || '';
            display($dbg_sr,2,"window($id) data='$data' str='$config_str'");

            if (!$frame)
            {
                $frame = new Pub::WX::FloatingFrame(
                    $this,
                    $frame_rect->x,
                    $frame_rect->y,
                    undef,
                    $config_id);
            }

            my $pane = $this->createPane($id,$frame->{book},$data,$config_str);

			# this RE is moderately dangerous inasmuch as there *could*
			# be other unexpected strings of the form (,|*)12123(,|;)

			my $new_id = $pane->{id};
			$pers =~ s/(,|\*)$orig_id(,|;)/$1$new_id$2/g if $instance && $pers;

            $frame->{manager}->Update();
            $id = shift(@parts);
        }

        if ($frame)
        {
            my $frame_perspective = readConfig("$config_id/perspective");
            if ($frame_perspective ne "")
            {
				display($dbg_sr,1,"got & fixing $config_id/perspective='$frame_perspective'");

                # replace the frame name with the new name
                # this is necessary or else LoadPerspective fails
                # because it can't find the frame
                $frame_perspective =~ s/name=content\(\d+\)/name=content\($fnum\)/;
				display($dbg_sr,2,"loading frame manager fixed perspective='$frame_perspective'");
                $frame->{manager}->LoadPerspective($frame_perspective)
            }
            $frame->SetSize($frame_rect);
            $frame->{manager}->Update();

			if ($pers ne '')
			{
				display($dbg_sr,1,"loading frame nb pers='$pers'");
				$frame->{book}->LoadPerspective($pers);
			}
            $frame->Show();
        }
        $fnum++;
        $config_id = "/frame$fnum";
    }

    # re-load and pass the main perspective

    $main_perspective = readConfig("perspective");
    if ($main_perspective ne "")
	{
		display($dbg_sr,0,"loading main perspective='$main_perspective'");
	    $this->{manager}->LoadPerspective($main_perspective,1);
	}

    display($dbg_sr,0,"finish Pub::WX::Frame::restore_state()");
    return 1;

}   # Pub::WX::Frame::restore_state()




#----------------------------
# Display Methods
#----------------------------

sub showError
{
    my ($this,$msg) = @_;
	my $dlg = Wx::MessageDialog->new($this,$msg,"Error",wxOK|wxICON_EXCLAMATION);
	$dlg->ShowModal();
}




#------------------------------------------------------
# notebooks
#------------------------------------------------------

sub getOpenNotebook
    # finds the named notebook and shows it if it
    # exists and is not showing. Creates and shows it
    # if it does not exist. Floating frame is passing
    # an extra third parameter 'this' for the floating
    # frame ($this is always the Pub::WX::Frame) ..
{
	my ($this,$name,$float_frame) = @_;
	display($dbg_frame,1,"getOpenNotebook($name)");
	my $book = $this->{notebooks}{$name};
	if (!$book)
	{
		$book = Pub::WX::Notebook->new($this,$name,$float_frame);
	}
	elsif (!$book->{is_floating})
	{
		my $pane = $this->{manager}->GetPane($book);
		if (!$pane->IsShown())
		{
			$pane->Show(1);
			$this->{manager}->Update();
		}
	}
	return $book;
}


sub getOpenDefaultNotebook
	# get resource description of the default notebook
	# and open a notebook as described
{
	my ($this,$id) = @_;
	display($dbg_frame,1,"getOpenDefaultNotebook($id)");
	my $r_data = ${$resources->{pane_data}}{$id};
	my ($label,$book_name) = @$r_data;
	return $this->getOpenNotebook($book_name);
}



sub findPageBook
    # return the book and pageid for a given page (pane)
{
	my ($this,$page) = @_;
	my $r_books = $this->{notebooks};
	foreach my $bname (keys(%$r_books))
	{
		my $book = $$r_books{$bname};
		my $idx  = $book->GetPageIndex($page);
		return ($book,$idx) if ($idx ge '0');
	}
}


sub onOpenNotebook
	# Toggles the state of a notebook showing, by ID
    # Is only intended to handle commands to show main
    # window notebooks, nothing fancy like floating frames.
{
	my ($this,$event) = @_;
	my $id = $event->GetId();
    my $notebook_name = $resources->{notebook_name};
	my $nbname = $$notebook_name{$id};
	my $book = $this->{notebooks}{$nbname};
    my $book_pane = $this->{manager}->GetPane($book);
    if (!$notebook_name || !$nbname || !$book || !$book_pane)
    {
        error("Could not find notebook info: id=$id notebook_name=$notebook_name nbname=$nbname book=$book book_pane=$book_pane");
        return;
    }

	display($dbg_frame,0,"onOpenNotebook($nbname)");

	if ($book_pane->IsShown())
	{
		display($dbg_frame,1,"hiding notebook");
		$this->{manager}->GetPane($book)->Hide();
	}
	else
	{
		display($dbg_frame,1,"showing notebook");
		$this->{manager}->GetPane($book)->Show(1);
	}
	$this->{manager}->Update();
}



#------------------------------------------------------
# panes
#------------------------------------------------------


sub createPane
	# base class factory does nothing and should probably be removed
	# would like to remove base class createPane method?
{
	my ($this,$id,$book,$data,$config_str) = @_;
	display($dbg_frame,1,"UNUSED Pub::WX::Frame::createPane($id) called ... book=".($book?$book->{name}:'undef'));
	if (!$id)
	{
		error("No id specified in Pub::WX::Frame::createPane()");
		return;
	}
    if (!$book)
    {
        $book = $this->getOpenDefaultNotebook($id);
    }
	error("Unknown pane id=$id in Pub::WX::Frame::createPane()");
}



sub addPane
	# set pane into list of all panes, and make it current
{
	my ($this,$pane) = @_;
	push @{$this->{panes}},$pane;
	display($dbg_frame,0,"added $pane");
	$this->setCurrentPane($pane);
}


sub removePane
{
	my ($this,$del_pane) = @_;
	display($dbg_frame,0,"removing $del_pane from frame::panes");
	for my $idx (0..@{$this->{panes}})
	{
		my $pane = @{$this->{panes}}[$idx];
		if ($pane && $pane == $del_pane)
		{
			display($dbg_frame,1,"-->found $del_pane");
			splice @{$this->{panes}},$idx,1;
			last;
		}
	}
	$this->setCurrentPane(undef);
}


sub getCurrentPane
{
	my ($this) = @_;
	return $this->{current_pane};
}


sub setCurrentPane
{
	my ($this,$pane) = @_;

	# if !$this->{running} we are shutting down
	# so we don't set the member

	my $cur = $this->getCurrentPane();
	if ($this->{running} && (
		defined($cur) != defined($pane) ||
		($pane && $pane != $cur)))
	{
		display($dbg_frame,0,"setCurrentPane(pane=".($pane?$pane:'undef').")");
		$this->{current_pane} = $pane;

		# this code *could* or perhaps *should* be in cmManager
		# there are no cases of member  pending_populate in mbeManager at this time

		if ($pane &&
			$pane->{pending_populate} &&
			$pane->can("populate"))
		{
			display($dbg_frame,0,"Pub::WX::Frame::setCurrentPane($pane->{label}) calling pending_populate()");
			$pane->populate();
			$pane->{pending_populate} = 0;
		}


		return $pane;
	}
}


sub findPane
{
	my ($this,$id) = @_;
	return if (!$id);
    for my $pane (@{$this->{panes}})
	{
		return $pane if ($pane->{id}==$id);
	}
}


sub findOrOpenPaneWithData
    # called by clients, will find or create the
    # given toolpane by id (single instance only)
    # and pass the given data to it.
{
    my ($this,$id,$data) = @_;
    my $pane = $this->findPane($id);
    if ($pane)
    {
        # derived classes must implement setFromConfigStr()

		if ($pane->can('setFromConfigStr'))
		{
			$pane->setFromConfigStr($data);
			$pane->populate();
		}
    }
    else
    {
        $pane = $this->createPane($id,"","",$data);
    }
    # my $book = $pane->{book};
    my $book = $pane->GetParent();
    my $idx = $book->GetPageIndex($pane);
    $book->SetSelection($idx);
    $pane->Show(1) if (!$pane->IsShown());
    $this->{manager}->Update();
}



sub findOrOpenMultipleInstancePane
	# find the existing multiple instance pane, if any
	# with the given base_id and data, create a new on
	# if not found.
{
	my ($this,$base_id,$data) = @_;
	display($dbg_frame,0,"findOrOpenMultipleInstancePane($base_id,$data)");

	my $found;
    for my $pane (@{$this->{panes}})
	{
		my $pane_instance = $pane->{instance} || 0;
		my $pane_base = $pane->{id} - $pane_instance;
		display($dbg_frame,1,"checking $pane($pane_base,$pane_instance)");

		if ($pane_base == $base_id && $pane->{data} eq $data)
		{
			$found = $pane;
			display($dbg_frame,1,"found($pane) = $pane->{id} = $pane->{data}");
			last;
		}
	}

	if (!$found)
	{
        $found = $this->createPane($base_id,'',$data,'');
	}

	return $found;
}



sub onOpenPane
	# Called directly from an event, this method
    # creates a window, and if necessary, a notebook,
    # based on the event ID. It uses the factory method
    # which only includes the monitorWindow in the base
    # class.
{
	my $book;
	my ($this,$event) = @_;
	my $id = $event->GetId();
	my $pane = $this->findPane($id);
	display($dbg_frame,1,"onOpenPane($id) existing=".($pane?$pane:'undef'));

	# if the pane does exist, get the real notebook
	# if the pane doesn't exist, use the default notebook

	if ($pane)
	{
		# $book = $pane->{book};
		$book = $pane->GetParent();
		if (!$book)
		{
			error("existing pane($pane->{title}) has no parent","orange");
			return;
		}
		my $book_pane = $this->{manager}->GetPane($book);
		if (!$book_pane)
		{
			error("Could not find book_pane for $book");
			return;
		}
		if (!$book_pane->IsShown())
		{
			display($dbg_frame,1,"showing notebook");
			$this->{manager}->GetPane($book)->Show(1);

		}
	}
	else
	{
		$book = $this->getOpenDefaultNotebook($id);
		$pane = $this->createPane($id,$book);
	}

	# make it the current tab and show it if necessary

	if ($pane)
    {
        my $idx = $book->GetPageIndex($pane);
        $book->SetSelection($idx);
        $pane->Show(1) if (!$pane->IsShown());
        $this->{manager}->Update();
    }
}



#------------------------------------------------------
# Commands implemented in base class
#------------------------------------------------------


sub onCloseWindows
	# Close all, or most of the windows in the system.
	#
	# Called by events $CLOSE_ALL_PANES and $CLOSE_OTHER_PANES
	# and frame::onClose(), or explicitly with no event i.e.
	# when changing logins or re-initialize database, etc.
	#
	# Only in the cases of $CLOSE_PANES ui events do we call
	# each window's autoClose() method to see if it normally
	# closes (default == yes) during these events.
	#
	# Otherwise, for each window we call it's closeOK() method
	# where it returns:
	#
	#  	0 to not close the window and stop the loop.
	#  	1 to close the window and continue the loop.
	#  -1 to close the window, and continue the loop,
	#     but not call closeOK() any more (abandon all changes).
{
	my ($this,$event) = @_;
    my $id = $event ? $event->GetId() : 0;
    my $skip = ($id == $CLOSE_OTHER_PANES) ? $this->getCurrentPane() : undef;
	my $check_auto = ($id == $CLOSE_ALL_PANES) || ($id == $CLOSE_OTHER_PANES) ? 1 : 0;

	display($dbg_frame,-1,"onCloseWindows($id,$check_auto) skip="._def($skip));

	my $rslt = 1;
	my @panes = @{$this->{panes}};
    for my $pane (@panes)
    {
		display($dbg_frame,-11,"checking($rslt) $pane(".$pane->GetId().") title="._def($pane->{title}));

        if ($pane &&
			(!$skip || $pane != $skip) &&
			(!$check_auto || $pane->autoClose()) &&
			($rslt == -1 || ($rslt = $pane->closeOK())))
		{
			# my $book = $pane->{book};
			my $book = $pane->GetParent();
			$book->closeBookPage($pane);
		}
		last if !$rslt;
	}

	$event->Skip() if $event && $rslt;
	display($dbg_frame,-1,"onCloseWindows() reutrning rslt="._def($rslt));
	return $rslt;
}



sub onCloseWindowsUI
{
	my ($this,$event) = @_;
    my $id = $event->GetId();
    my $panes = $this->{panes};
    my $skip = ($id == $CLOSE_OTHER_PANES) ? $this->getCurrentPane() : undef;
	$skip = undef if $skip && (!$skip->can('autoClose') || !$skip->autoClose());
	my $enable = 0;

	if ($id != $CLOSE_OTHER_PANES || $skip)
	{
		for my $pane (@$panes)
		{
	        if ($pane && (!$skip || $pane != $skip) &&
				$pane->can('autoClose') &&
				$pane->autoClose())
			{
				$enable = 1;
				last;
			}
		}
	}
	$event->Enable($enable);
}



1;
