#!/usr/bin/perl
#-----------------------------------------------
# a global LWP::UserAgent
#-----------------------------------------------
#
# - setup to work with HTTPS (ignore certificates)
# - has a few additional routines (ua_credentials)


package Pub::UA;
use strict;
use warnings;
use HTML::Form;
use IO::Socket::SSL qw(SSL_VERIFY_NONE);
use Pub::Crypt;
use Pub::Utils qw(error display printVarToFile $temp_dir);
use base qw(LWP::UserAgent);


our $dbg_ua = 0;
our $dbg_cookies = 1;


# BEGIN { $ ENV{PERL_LWP_SSL_VERIFY_HOSTNAME} = 0; }
#
# I needed to add this when I udpated SSL on my home machine,
# and then, it didn't work until I installed LWP::Protocol-https,
# which in turn needed Mozilla::CA. Thi is instead accomplished
# by passing in ssl_opts => {verify_hostname=>0} into
# the LWP::UserAgent constructor
#


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (
		init_pub_ua
    );
}


#-------------------------------------------------------
# client may choose to use a single static $global_ua
#-------------------------------------------------------
# esp in long lived apps


my $global_ua;

sub init_pub_ua
{
	$global_ua ||= Pub::UA->new();
	return $global_ua;
}



sub ua_credentials
{
	my ($this,$domain,$realm,$enc_id,$enc_pass) = @_;
	$this->credentials($domain,$realm,
		my_decrypt($enc_id),
		my_decrypt($enc_pass));
}

sub new
{
    my ($class,@params) = @_;
    my $this = $class->SUPER::new(
		# max_redirect => 0,
		env_proxy => 1,
		timeout   => 30,
		ssl_opts => {
			verify_hostname => 0,
			SSL_verify_mode => SSL_VERIFY_NONE },
		@params);

	# my $jar = HTTP::Cookies->new(ignore_discard => 1);

	$this->agent('Mozilla/5.0 (Windows NT 6.1; WOW64; rv:17.0) Gecko/20100101 Firefox/17.0');
	# $this->agent('Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:59.0) Gecko/20100101 Firefox/59.0');

	# $this->cookie_jar($jar);

    return $this;
}





1;
