#!/usr/bin/perl
#---------------------------------------
# Pub::Prefs
#---------------------------------------
# A simple text file based preferences file.

package Pub::Prefs;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use Pub::Crypt;

# Clients call Pub::Prefs::initPrefs(), probably after
# the $data_dir is setup.
#
# setPrefEncrypted() and getPrefDecrypted() require the
# use of an external $crypt_key_file.  $crypt_key_file
# may be left blank if you don't use those routines.
#
# Note that you should NEVER store any encrypted
# prefs in any source code or repositories. You
# *may* provide blanks for defaults, and allow the
# program to set them where they will only live in
# memory for a short while.
#
# Default Preferences are an array of ID => value pairs.
# This determines the order they are written to the file.
# There should generally be no defaults (except blank)
# for encryped prefs.
#
# Example:
#
#	our	$PREF_RENDERER_MUTE = "RENDERER_MUTE";
#	our $PREF_RENDERER_VOLUME = "RENDERER_VOLUME";
#
# 	sub init_app_prefs
#	{
#		Pub::Prefs::initPrefs(
#			"$data_dir/app.prefs",
#			"/dat/Private/app/private_crypt_key.txt",
#			{
#				$PREF_RENDERER_MUTE => 0,
#				$PREF_RENDERER_VOLUME => 80,
#			});
#	}


my $dbg_prefs = 1;
	# 0 = show static_init_prefs() header msg
	# -1 = show individual setPrefs


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (
		getPref
		setPref
		getPrefDecrypted
		setPrefEncrypted
    );
}


my $global_prefs:shared;
my $pref_filename:shared;


#---------------------------------------
# accessors
#---------------------------------------

sub getPref
{
	my ($id) = @_;
	return $global_prefs->{$id};
}

sub setPref
{
	my ($id,$value) = @_;
	display($dbg_prefs+1,0,"setPref($id,$value)");
	$global_prefs->{$id} = $value;
	write_prefs();
}


sub getPrefDecrypted
	# the result from this should be used
	# and de-allocated as quickly as possible
{
	my ($id) = @_;
	my $value = getPref($id);
	return my_decrypt($value);
}


sub setPrefEncrypted
	# the result from this should be used
	# and de-allocated as quickly as possible
{
	my ($id,$value) = @_;
	my $encrypted = my_encrypt($value);
	display($dbg_prefs+1,0,"setPrefEncrypted($id,$encrypted)");
	setPref($id,$encrypted);
}


#-----------------------------------------
# read and write text file
#-----------------------------------------

sub initPrefs
{
	my ($filename,$crypt_file,$defaults) = @_;
	$crypt_file ||= '';
	$defaults ||= {};
	display($dbg_prefs,0,"initPrefs($filename,$crypt_file)");
	$pref_filename = $filename;
	$global_prefs = shared_clone($defaults);
	init_crypt($crypt_file) if $crypt_file;

	if (-f $pref_filename)
	{
	    my @lines = getTextLines($pref_filename);
        for my $line (@lines)
        {
			$line =~ s/#.*$//;
			$line =~ s/^\s+|\s+$//g;
			my $pos = index($line,'=');
			if ($pos > 1)
			{
				my $left = substr($line,0,$pos);
				my $right = substr($line,$pos+1);
				$left =~ s/^\s+|\s+$//g;
				$right =~ s/^\s+|\s+$//g;
				display($dbg_prefs,0,"pref($left)='$right'");
				$global_prefs->{$left} = $right;
		    }
		}
    }
}


sub write_prefs
{
    my $text = '';
    for my $k (sort(keys(%$global_prefs)))
    {
        $text .= "$k=$global_prefs->{$k}\n";
    }
    if (!printVarToFile(1,$pref_filename,$text,1))
    {
        error("Could not write prefs to $pref_filename");
        return;
    }
    return 1;
}




1;
