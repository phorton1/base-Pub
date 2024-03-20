#!/usr/bin/perl
#---------------------------------------
# Pub::Prefs
#---------------------------------------
# A simple text file based preferences file, with
# comment preserving, non-default writing. The client
# must call explicitly call writePrefs() after calling
# setPref, setPrefEncrypted, or setPrefSequenced.
#
# Any line that matches a default value will be
# commented out.
#
# If a line that has a different value than the pref,
# that line will be changed, and the line rewritten.
#
# Otherwise, new lines will be added after a blank line
# at the end, with a DT stamp comment.

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

		initPrefs
		writePrefs

		getPref
		getPrefDecrypted
		getSequencedPref

		setPref
		setPrefEncrypted
		getSequencedPref

		getObjectPref
		copyParamsWithout

    );
}

my $pref_filename:shared = '';
my $prefs:shared = shared_clone({});;
my $pref_defaults:shared = shared_clone({});



#---------------------------------------
# accessors
#---------------------------------------

sub getPref
{
	my ($id) = @_;
	display($dbg_prefs+1,0,"getPref($id)");
	return $prefs->{$id};
}

sub getPrefDecrypted
	# the result from this should be used
	# and de-allocated as quickly as possible
{
	my ($id) = @_;
	my $value = getPref($id);
	return my_decrypt($value);
}

sub getSequencedPref
	# finds a sequence of prefs of the form $id_NN
	# starting at zero
{
	my ($id) = @_;
	my $num = 0;
	my $rslt = [];
	my $value = getPref($id."_".$num++);
	while (defined($value))
	{
		push @$rslt,$value;
		$value = getPref($id."_".$num++);
	}
	return $rslt;
}




sub setPref
{
	my ($id,$value) = @_;
	display($dbg_prefs,0,"setPref($id,$value)");
	$prefs->{$id} = $value;
}


sub setPrefEncrypted
	# the result from this should be used
	# and de-allocated as quickly as possible
{
	my ($id,$value) = @_;
	my $encrypted = my_encrypt($value);
	display($dbg_prefs,0,"setPrefEncrypted($id,$encrypted)");
	setPref($id,$encrypted);
}



sub setSequencedPref
	# sets a sequence of prefs of the form $id_NN
	# starting at zero, clearing any previous
{
	my ($id,$values) = @_;
	display($dbg_prefs,0,"setSequencedPref($id)\r".join("\r".@$values));

	my @deletes;
	my $base = $id."_";
	for my $key (sort keys %$prefs)
	{
		push @deletes,$key if $key =~ /^$base\d+$/;
	}
	for my $del (@deletes)
	{
		delete $prefs->{key};
	}

	my $num = 0;
	for my $value (@$values)
	{
		$value = '' if !defined($value);
		$prefs->{$base.$num} = $value;
	}
}


#-----------------------------------------
# initPrefs
#-----------------------------------------

sub initPrefs
	# The program prefs file may contain a CRYPT_FILE
	# preference which overrides that provided by the
	# caller.
{
	my ($filename,$defaults,$crypt_file,$show_init_prefs) = @_;
	$crypt_file ||= '';
	$defaults ||= {};
	$show_init_prefs ||= 0;

	my $use_dbg = $show_init_prefs ? 0 : $dbg_prefs;
	display($use_dbg,0,"initPrefs($filename,$crypt_file)");

	$pref_filename = $filename;
	$prefs = shared_clone($defaults);
	$pref_defaults = shared_clone($defaults);

	readPrefs();

	if ($prefs->{CRYPT_FILE})
	{
		$crypt_file = $prefs->{CRYPT_FILE};
		display($dbg_prefs,1,"using pref CRYPT_FILE=$crypt_file");
	}

	init_crypt($crypt_file) if $crypt_file;

	if ($show_init_prefs)
	{
		for my $key (sort keys %$prefs)
		{
			display(0,1,"pref($key) = '$prefs->{$key}'");
		}
	}

}




sub readPrefs
{
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
				display($dbg_prefs+1,0," readPref($left)='$right'");
				$prefs->{$left} = $right;
		    }
		}
    }
}


sub writePrefs
{
	display($dbg_prefs,0,"writePrefs($pref_filename)");

    my $text = '';
	my $found = {};
	my @lines = getTextLines($pref_filename);

	for my $line (@lines)
	{
		my $new_line = $line;
		my $comment = $line =~ s/(\s+#.*)$// ? $1 : '';
		my $lead_white =$line =~ s/^(\s+)// ? $1 : '';
		my $pos = index($line,'=');
		if ($pos > 1)
		{
			my $left = substr($line,0,$pos);
			my $right = substr($line,$pos+1);
			$left =~ s/^\s+|\s+$//g;
			$right =~ s/^\s+|\s+$//g;

			$found->{$left} = 1;

			my $value = $prefs->{$left};
			my $default = $pref_defaults->{$left};

			# comment out existing line that matches default
			# value or change existing line that changed ..

			if (defined($value))
			{
				if (defined($default) && $value eq $default)
				{
					$new_line = '# '.$new_line;
				}
				elsif ($right ne $value)
				{
					$new_line = $lead_white.$left.' = '.$value.$comment;
				}
			}

			$text .= $new_line."\n";
		}
	}

	my $extra_added = 0;
    for my $id (sort(keys(%$prefs)))
    {
		next if $found->{$id};

		my $default = $pref_defaults->{$id};
		my $value = $prefs->{$id};
		$value = '' if !defined($value);
		next if defined($default) && $value eq $default;

		$text .= "\n" if !$extra_added;
		$extra_added++;
        $text .= "$id = $value\n";
    }
    if (!printVarToFile(1,$pref_filename,$text,1))
    {
        error("Could not write prefs to $pref_filename");
        return 0;
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
