#!/usr/bin/perl
#---------------------------------------
# Pub::Prefs
#---------------------------------------
# A simple text file based preferences file.
#
# Program preferences are read-only, highly edited
# files with comments in them.
#
# User preferences are writable, alphabetized,
# and destroy comments.


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


my $dbg_prefs = 0;
	# 0 = show static_init_prefs() header msg
	# -1 = show individual setPrefs


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (
		getPref
		setPref
		getObjectPref
		copyParamsWithout

		getUserPref
		setUserPref
		getPrefDecrypted
		setPrefEncrypted
    );
}


my $program_prefs:shared = shared_clone({});;
my $user_prefs:shared = shared_clone({});;
my $user_pref_filename:shared = '';


#---------------------------------------
# accessors
#---------------------------------------

sub getPref
{
	my ($id) = @_;
	display($dbg_prefs+1,0,"getPref($id)");
	return $program_prefs->{$id};
}

sub getPrefDecrypted
	# the result from this should be used
	# and de-allocated as quickly as possible
{
	my ($id) = @_;
	my $value = getPref($id);
	return my_decrypt($value);
}



sub getUserPref
{
	my ($id) = @_;
	display($dbg_prefs+1,0,"getUserPref($id)");
	return $user_prefs->{$id};
}

sub setUserPref
{
	my ($id,$value) = @_;
	display($dbg_prefs,0,"setUserPref($id,$value)");
	$user_prefs->{$id} = $value;
	write_user_prefs();
}


sub getUserPrefDecrypted
	# the result from this should be used
	# and de-allocated as quickly as possible
{
	my ($id) = @_;
	my $value = getUserPref($id);
	return my_decrypt($value);
}

sub setUserPrefEncrypted
	# the result from this should be used
	# and de-allocated as quickly as possible
{
	my ($id,$value) = @_;
	my $encrypted = my_encrypt($value);
	display($dbg_prefs,0,"setPrefEncrypted($id,$encrypted)");
	setUserPref($id,$encrypted);
}


#-----------------------------------------
# initPrefs
#-----------------------------------------

sub initPrefs
	# The program prefs file may contain a CRYPT_FILE
	# preference which overrides that provided by the
	# caller.
{
	my ($filename,$defaults,$crypt_file) = @_;
	$crypt_file ||= '';
	$defaults ||= {};

	display($dbg_prefs,0,"initPrefs($filename,$crypt_file)");

	$program_prefs = shared_clone($defaults);
	read_prefs(0,$program_prefs,$filename);

	if ($program_prefs->{CRYPT_FILE})
	{
		$crypt_file = $program_prefs->{CRYPT_FILE};
		display($dbg_prefs,1,"using pref CRYPT_FILE=$crypt_file");
	}

	init_crypt($crypt_file) if $crypt_file;
}


sub initUserPrefs
{
	my ($filename,$defaults) = @_;;
	$defaults ||= {};

	display($dbg_prefs,0,"initUserPrefs($filename)");

	$user_prefs = shared_clone($defaults);
	read_prefs(1,$user_prefs,$filename);
	$user_pref_filename = $filename;
}



sub read_prefs
{
	my ($user,$prefs,$filename) = @_;
	if (-f $filename)
	{
	    my @lines = getTextLines($filename);
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
				display($dbg_prefs+1,0,($user?"USER":"PROGRAM")." pref($left)='$right'");
				$prefs->{$left} = $right;
		    }
		}
    }
}


sub write_user_prefs
{
	display($dbg_prefs,0,"write_user_prefs($user_pref_filename)");
    my $text = '';
    for my $k (sort(keys(%$user_prefs)))
    {
        $text .= "$k=$user_prefs->{$k}\n";
    }
    if (!printVarToFile(1,$user_pref_filename,$text,1))
    {
        error("Could not write prefs to $user_pref_filename");
        return;
    }
    return 1;
}




#-----------------------------------------
# support for object $param ctors
#-----------------------------------------

sub getObjectPref
	# For a given ID to for a param in an object ctor,
	# See if a preference is defined, and use that if so,
	# Otherwise, if a param is provided, use that.
	# And only if all else fails, use the $default.
	#
	# force_undef is used by knowledgable objects to prevent
	#	cluttering params with non-sensical sub params when
	#   a major param turns on/off a whole set of param.
	#
	# Params prefiex in the ctor with FORCE_ will override
	# the parameters.
{
	my ($params,$id,$default,$force_undef) = @_;
	if ($force_undef)
	{
		display($dbg_prefs+1,0,"getObjectPref($id) forcing undef");
		delete $params->{$id};
		return;
	}

	my $force_id = 'FORCE_'.$id;
	if (defined($params->{$force_id}))
	{
		$params->{$id} = $params->{$force_id};
		delete $params->{$force_id};
		display($dbg_prefs+1,0,"getObjectPref($id) $force_id '$params->{$id}'");
		return;
	}

	my $pref_val = getPref($id);
	if (defined($pref_val))
	{
		$params->{$id} = $pref_val;
		display($dbg_prefs+1,0,"getObjectPref($id) got pref '$params->{$id}'")
	}
	elsif (defined($params->{$id}))
	{
		display($dbg_prefs+1,0,"getObjectPref($id) using ctor param '$params->{$id}'")
	}
	elsif (defined($default))
	{
		display($dbg_prefs+1,0,"getObjectPref($id) setting to default '$default'");
		$params->{$id} = $default;
	}
	else
	{
		display($dbg_prefs+1,0,"getObjectPref($id) == undef");
	}
}

sub copyParamsWithout
	# common method (FS and HTTP) to remove leading
	# FS_ or HTTP_ from SSL and other params for
	# portForwarder
{
	my ($params,$without) = @_;
	my $new_params = {};
	for my $id (keys %$params)
	{
		my $val = $params->{$id};
		$id =~ s/^$without//;
		$new_params->{$id} = $val;
	}
	return $new_params;
}



1;
