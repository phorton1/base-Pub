#!/usr/bin/perl
#-----------------------------------------------------
# Pub::IOT::WiFi.pm
#-----------------------------------------------------
# A cross platform "monitor" for wifi status.
# Calls "ipconfig /all" on windows and "iwconfig

package Pub::IOT::Wifi;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;

my $dbg_wifi = 0;


my $REFRESH_TIME = 5;
my $REPORT_TIME = 900;


my $wifi_connected:shared = 0;
my $wifi_thread;
my $wifi_rssi = 0;


sub connected
{
    return $wifi_connected;
}


sub start
{
    display($dbg_wifi,0,"Pub::IOT::WiFi::start() called");
	$wifi_thread = threads->create(\&wifiThread);
	$wifi_thread->detach();
	display($dbg_wifi,0,"Pub::IOT::WiFi::start() returning");
}


sub wifiThread
{
    display($dbg_wifi,0,"wifiThread() started");
    my $last_check = 0;
    my $last_report = 0;

    while (1)
    {
        my $now = time();
        if ($now > $last_check + $REFRESH_TIME)
        {
            $last_check = $now;
            my $got_connected = 0;
            display($dbg_wifi+1,0,"checking wifi ...");
            if (is_win())
            {
                my $text = `ipconfig /all`;
                my @parts = split(/Wireless LAN adapter Wi-Fi:/,$text);
                if (@parts > 1)
                {
                    if ($parts[1] =~ /IPv4 Address.*:\s*(\d+\.\d+\.\d+\.\d+)/)
                    {
                        my $ip = $1;
                        display($dbg_wifi+1,-1,"win wifi connected with ip=$ip");
                        $got_connected = 1;
                    }
                    else
                    {
                        warning($dbg_wifi+1,-1,"win wifi disconnected!");
                    }
                }
            }
            else    # rPi
            {
                my $text = `iwconfig wlan0`;
                if ($text =~ /ESSID:"(.*?)"/)
                {
                    my $ssid = $1;
                    display($dbg_wifi+1,-1,"rpi wifi connected to ssid=$ssid");
                    $got_connected = 1;
                }
                else
                {
                    warning($dbg_wifi+1,-1,"rpi wifi disconnected!");
                }

                if ($now > $last_report + $REPORT_TIME)
                {
                    $last_report = $now;
                    if ($text =~ /Signal level=(-\d+)/)
                    {
                        my $rssi = $1;
                        if (abs($wifi_rssi - $rssi) > 4)
                        {
                            $wifi_rssi = $rssi;
                            LOG(-1,"WIFI RSSI=$rssi");
                        }
                    }
                }
            }

            if ($got_connected != $wifi_connected)
            {
                LOG(-1,"=============== WIFI ".($got_connected?"CONNECTED":"DISCONNECTED")."===============");
                $wifi_connected = $got_connected;
                $wifi_rssi = 0 if !$got_connected;
            }
        }
    }
}


#------------------------------------------
# selfTest
#------------------------------------------


if (0)      # self test
{
    start();
    while (1)
    {
        sleep(1);
    }
}


1;