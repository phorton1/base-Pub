#!/usr/bin/perl
#--------------------------------------------------------
# Pub::Crypt - Lightweight RC4 encryption
#--------------------------------------------------------
# These routines are used to encrypt and decrypt strings
# using the somewhat insecure RC4 encryption with an application
# or system specific private key stored in a known file.
#
# Strings encrypted in this way,and the private key itself,
# should not be present in source code or any repositories.

package Pub::Crypt;
use strict;
use warnings;
use threads;
use threads::shared;
use Crypt::RC4;
use Pub::Utils;


my $dbg_crypt = 0;

BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (

		init_crypt
		my_encrypt
		my_decrypt
    );
};



my $private_key = '';


sub init_crypt
{
	my ($crypt_file) = @_;
	display($dbg_crypt,0,"init_crypt($crypt_file)");
	my $text = getTextFile($crypt_file) || '';
	$text =~ s/^\s+|\s$//g;
	error("No private_key in init_crypt($crypt_file)") if !$text;
	$private_key = $text;
}




sub my_encrypt
{
	my ($text) = @_;
	my $encrypt = crypt_rc4($text);
	return encode64($encrypt);
}


sub my_decrypt
{
	my ($text) = @_;
	my $decode = decode64($text);
	return crypt_rc4($decode);
}



sub crypt_rc4
{
    my ($msg) = @_;
	if (!$private_key)
	{
		error("No private_key in crypt_rc4()");
		return '';
	}

    my $rc4 = Crypt::RC4->new($private_key );
    return $rc4->RC4( $msg );
}




1;
