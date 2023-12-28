#--------------------------------------------------
# Pub::ComPorts
#--------------------------------------------------
# Find connected COM ports and return hash where
# the keys are COM6, COM7, etc, and the records contain
#
#      num - the com port number
#      serial_num - a serial number associated with the device
#      friendly-name - for MIDI composite devices, i.e. "teensyExpression"
#
# Usage:  my $hash = Pub::ComPorts::find();

package Pub::ComPorts;
use strict;
use warnings;
use Win32::TieRegistry qw(KEY_READ);
use Pub::Utils;

my $dbg_dev = 1;

my $ports_key = 'HKEY_LOCAL_MACHINE\Hardware\DEVICEMAP\SERIALCOMM';
my $usb_devices_key = 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\USB';


sub knownDevice
{
	my ($vid,$pid,$mi) = @_;
	return if !$vid || !$pid;

	# from devicehunt.com and other sources

	return "Arduino Uno" 	if $vid eq '2341' && $pid eq '0001';
	return "Arduino Uno R3" if $vid eq '2341' && $pid eq '0043';
	return "Arduino"		if $vid eq '2341';

	# from my actual devices

	return 'ESP32 Dev'		if $vid eq '10C4' && $pid eq 'EA60';
		# for my ESP32 Dev with or without holes,
		# The WEMOS Lolin32 with the battery connectors
	return 'teensy 3.6' 	if $vid eq '16C0' && $pid eq '0489';	# 0489 not specified at devicehunt.com
	return 'teensy 3.2' 	if $vid eq '16C0' && $pid eq '0483';	# 0483 == Teensyduino Serial
	return 'Arduino Nano' 	if $vid eq '04D9' && $pid eq 'B534';
	return 'Arduino'		if $vid eq '1A86' && $pid eq '7523';
		# I get this for both my UNO R3 and my UNO MEGA2560
		# and my old nano with the USB mini port, as well as
		# my ESP32 cam boards, the LilyGo 20-6-18 v1.1,
	return '';
}


sub find
{
    my $retval = {};
    # my $registry = $Win32::TieRegistry::Registry;
    my $ports = $Registry->Open($ports_key,{ Access=>KEY_READ });
    my $usb_devices = $Registry->Open($usb_devices_key,{ Access=>KEY_READ });

	display($dbg_dev,0,"buildComPortInfo()");

    for my $port_type (keys %$ports)
    {
        my $com_port = $ports->{$port_type};                            # $com_port = COM6, teensyExpression2
        $com_port =~ /COM(\d+)$/;

		display($dbg_dev,1,"com_port = $com_port");

        my $port_num = $1;												# $port_num = 6
        my $info = { num => $port_num };
        $retval->{$com_port} = $info;

        for my $device_id (keys %$usb_devices)                          # $device_id = VID_16C0&PID_0489&MI_00/
        {
            my $usb_entry = $usb_devices->{$device_id};
            $device_id =~ s/\\$//;                                      # $device_id = VID_16C0&PID_0489&MI_00

            for my $device_num (keys %$usb_entry)                       # $device_num = 8&23c905d&0&0000/
            {
                my $entry = $usb_entry->{$device_num};
                $device_num =~ s/\\$//;                                 # $device_num = 8&23c905d&0&0000
                my $params = $entry->{'Device Parameters'};
                my $port_name = $params ? $params->{PortName} : '';
                $port_name ||= '';

                # found the COM port!!

                if ($port_name eq $com_port)                            # COM6 eq COM6
                {
					display($dbg_dev,2,"found $device_id=$device_id");

					$info->{VID} = $1 if $device_id =~ /VID_([0-9A-F]+)/;
					$info->{PID} = $1 if $device_id =~ /PID_([0-9A-F]+)/;
					$info->{MI} = $1 if $device_id =~ /MI_([0-9A-F]+)/;

					my $known_device = knownDevice($info->{VID},$info->{PID},$info->{MI});
					$info->{device} = $known_device if $known_device;

                    my $num_key = $usb_devices_key."\\".$device_id."\\".$device_num;
                    my $num_entry = $Registry->Open( $num_key,{ Access=>KEY_READ });

                    my $container_id = $num_entry->{"\\ContainerID"};
                        # #container_id = {be3a7aa2-f62b-51a3-bd84-72ecf9054746}
                    my $hardware_id = $num_entry->{"\\HardwareID"};
                        # $hardware_id =
                        #   USB\VID_16C0&PID_0489&REV_0211&MI_00 \x00
                        #   USB\VID_16C0&PID_0489&MI_00
                        # The hardware_id is a \x00 delimited multi-string where
                        # the first part contains the REV and the second part
                        # is the same as the $device_id

					display($dbg_dev,3,"hardware_id = $hardware_id");
					display($dbg_dev,3,"container_id = $container_id");

                    # if it's not a composite device, then we will consider
                    # the serial number to be $device_num, and there is no
                    # usable friendly name

                    if ($device_id !~ /&MI_../)
                    {
                        $info->{serial_num} = $device_num;					# 5564050 for COM11 - teensyPiLooper
						display($dbg_dev,3,"serial_num = $device_num");
						last;
                    }

                    # otherwise, go to the parent device and look for
                    # the serial number by matching container and hardware id's

                    else
                    {
                        my $parent_id = $device_id;
                        $parent_id =~ s/&MI_..//;                           # $parent_id = VID_16C0&PID_0489
						my $parent_hardware_id = $hardware_id;
                        $parent_hardware_id =~ s/&MI_..//g;
							# $parent_hardware_id =
							#   USB\VID_16C0&PID_0489&REV_0211 \x00
							#   USB\VID_16C0&PID_0489

						display($dbg_dev,3,"parent_id = $parent_id");
						display($dbg_dev,3,"parent_hardware_id = $parent_hardware_id");

                        my $parent_entry = $usb_devices->{$parent_id};
                        for my $serial_num (keys %$parent_entry)            # $serial_num = TE00000001/
                        {
							my $num_entry = $parent_entry->{$serial_num};
							# display_hash(0,6,"num_entry($serial_num)",$num_entry);

							my $prefix = $num_entry->{'\\ParentIdPrefix'};

							display($dbg_dev+1,5,"checking serial_num = $serial_num");
							display($dbg_dev+1,6,"prefix = $prefix");
							display($dbg_dev+1,5,"container_id = $num_entry->{'\\ContainerID'}");
							display($dbg_dev+1,6,"hardware_id = $num_entry->{'\\HardwareID'}");

                            if ($device_num =~ /^$prefix/ &&
								$container_id eq $num_entry->{'\\ContainerID'} &&
								$parent_hardware_id eq $num_entry->{'\\HardwareID'})
                            {
                                $serial_num =~ s/\\$//;						# $serial_num = TE00000001
                                $info->{serial_num} = $serial_num;
								display($dbg_dev,3,"serial_num = $serial_num");
								last;
                            }
                        }

                        # and since it's a composite device, get the
                        # friendly name of the MIDI device (the software
                        # device in deviceManager) from the MI_02

                        my $midi_id = $device_id;
                        $midi_id =~ s/&MI_00/&MI_02/;                     # $midi_id = VID_16C0&PID_0489&MI_02
                        my $midi_hardware_id = $hardware_id;
                        $midi_hardware_id =~ s/&MI_00/&MI_02/g;
                            # $parent_hardware_id =
                            #   USB\VID_16C0&PID_0489&REV_0211&MI_02 \x00
                            #   USB\VID_16C0&PID_0489&MI_02

						display($dbg_dev,4,"midi_id = $midi_id");
						display($dbg_dev,4,"midi_hardware_id = $midi_hardware_id");

                        my $midi_entry = $usb_devices->{$midi_id};
                        for my $midi_num (keys %$midi_entry)                # $midi_num = 8&23c905d&0&0002/
                        {
                            my $entry = $midi_entry->{$midi_num};
                            $midi_num =~ s/\\$//;                           # $midi_num = 8&23c905d&0&0002

							display($dbg_dev+1,5,"checking midi_num = $midi_num");
							display($dbg_dev+1,6,"container_id = $entry->{'\\ContainerID'}");
							display($dbg_dev+1,6,"hardware_id = $entry->{'\\HardwareID'}");

                            if ($container_id eq $entry->{"\\ContainerID"} &&
								$midi_hardware_id eq $entry->{"\\HardwareID"})
                            {
								my $midi_name = $entry->{"\\FriendlyName"} || '';
								$info->{midi_name} = $midi_name if $midi_name;	# teensyExpression
								display($dbg_dev,3,"midi_name = $midi_name");
								last;
                            }

						}	# for each MIDI_DEVICE $midi_num
                    }	# MI_00 device

					last;

                }	# found COM port
            }	# for each DEVICE $device_num
        }	# for each USB_DEVICE $device_id
    }	# for each port

    return $retval;
}





1;
