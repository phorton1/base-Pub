#!/usr/bin/perl
#-----------------------------------------------
# main
#-----------------------------------------------

package Pub::WX::Main;
use strict;
use threads;
use threads::shared;
use Error qw(:try);
use Wx qw(wxOK wxICON_EXCLAMATION);
use Pub::Utils;

my $dbg_main = 0;

use sigtrap 'handler', \&onSignal, 'normal-signals';
    # $SIG{INT} = \&onSignal; only catches ^c

sub onSignal
{
    my ($sig) = @_;
    LOG(-1,"main terminating on SIG$sig");
    kill 6,$$;
}

sub run
{
    my ($app) = @_;
    display($dbg_main,0,"starting run()");

    AFTER_EXCEPTION:

    try
    {
        $app->MainLoop();
        display($dbg_main,-1,"program shutting down ...");
    }

    catch Error with
    {
        my $ex = shift;   # the exception object
        display($dbg_main,0,"exception: $ex");
        error($ex);
        my $msg = "!!! main() caught an exception !!!\n\n";
        my $dlg = Wx::MessageDialog->new(undef,$msg.$ex,"Exception Dialog",wxOK|wxICON_EXCLAMATION);
        $dlg->ShowModal();
        goto AFTER_EXCEPTION if (1);
    };

    display($dbg_main,-1,"finishing run()");
}


1;
