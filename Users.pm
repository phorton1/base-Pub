#---------------------------------------
# Pub::Users.pm
#---------------------------------------
# Contains somewhat generalized scheme
# for managing user access to programs
# and websites.
#
# USERS.TXT is a text file of the form:
#
#    uid  pss  privs
#
#    where pss is the encrypted password
#    This file may contain coments and blank lines.
#
#    privs, by convention, is a comma delimited list of pid:level
#       where pid is a program id, and level is an integer, BUT NOTE
#       that the base My::HTTP::ServerBase.pm does NOT ENFORCE this
#       or check it in any way before passing it the higher level
#       derived HTTPS server ...
#
# ENC_USERS.TXT may also be used.
#
#    It is a line encrypted text file that
#    includes a final SHA checksum line of
#    the previous lines, and may not contain
#    comments.
#
# The functions here can open and read a users
# text file, return a given user, and or validate
# an https encrypted password.


package Pub::Users;
use strict;
use warnings;
use Digest::MD5;
use Pub::Utils;


our $dbg_user = 1;

BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw(
		getValidUser
		$USER_FILE_FIELDS
	);
};


our $USER_FILE_FIELDS = [qw(uid pss privs)];



sub getValidUser
	# return the user record for the $uid
{
	my ($enc,			# 1 = encrypted user file
		$filename,		# fully qualified filename
		$uid,			# the (required) user name
		$pss) = @_;		# the optional encrypted password to verify
	$enc ||= 0;
	$pss ||= '';
	$uid = lc($uid);

	display($dbg_user,0,"getValidUser($enc,$filename,$uid,$pss)");
	if (!$pss)
	{
		error("no password given for user $uid");
		return;
	}

	my $users = _getUserFile($enc,$filename);
	return if !$users;

	my $user = $users->{$uid};
	if (!$user)
	{
		error("No user '$uid' found in $filename");
		return;
	}

	return if !_validate($user,$pss);

	display($dbg_user,1,"getValidUser() returning $user->{uid} privs=$user->{privs}");
	return $user;
}



sub _getUserFile
{
	my ($enc,$filename,$no_errors) = @_;
	display($dbg_user,0,"_getUserFile($enc,$filename)");

	my $text = getTextFile($filename);
	if (!$text)
	{
		if ($no_errors)
		{
			display($dbg_user,1,"_getUserFile() could not read $filename");
			return ({},'');
		}
		error("Could not read $filename");
		return;
	}

	# get the enc checksum if needed

	my $cs;
	my $md5;
	my @lines = split(/\n/,$text);
	display($dbg_user,1,"got ".scalar(@lines)." lines of text");

	if ($enc)
	{
		$cs = my_decrypt(pop(@lines)) || '';
		display($dbg_user,1,"enc cs=$cs");
		$md5 = Digest::MD5->new();
	}

	# parse the lines into records

	my $hash = {};
	for my $line (@lines)
	{
		$line = my_decrypt($line) if $enc;
		$md5->add($line) if $enc;

		$line =~ s/#.*$//;
		$line =~ s/^\s*//;
		$line =~ s/\s*$//;
		next if !$line;

		my $rec = {};
		my @values = split(/\s+/,$line);
		display($dbg_user+1,1,"RECORD");

		for my $field (@$USER_FILE_FIELDS)
		{
			my $value = shift @values;
			$value = '' if !defined($value);
			$rec->{$field} = $value;
			display($dbg_user+1,2,pad($field,5)." = '$value'");
		}
		$hash->{$rec->{uid}} = $rec;
	}

	# check the encrypted checksum

	if ($enc)
	{
		my $calc = $md5->hexdigest();
		display($dbg_user,1,"enc calc=$cs");
		if ($calc ne $cs)
		{
			error("Bad checksum($calc,$cs) in $filename");
				# this is still reported as an error
				# even $if no_errors
			return;
		}
	}

	display($dbg_user,1,"_getUserFile() returning ".scalar(keys(%$hash))." records");
	return $hash if !wantarray;

	# return the checksum in an array context

	return ($hash,$cs);

}	# _getUserFile




sub _validate
	# simply compares the encrypted password
	# to the encrypted password in the record
{
	my ($user,$pss) = @_;
	display($dbg_user,0,"_validate($user,$pss) user->{pss}=$user->{pss}");
	if ($pss ne $user->{pss})
	{
		error("Invalid Login for $user->{uid}: $pss");
		return;
	}
	display($dbg_user,1,"_validate($user->{uid}) returning 1");
	return 1;
}




1;
