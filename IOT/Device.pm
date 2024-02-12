#!/usr/bin/perl
#-----------------------------------------------------
# Pub::IOT::Device.pm
#-----------------------------------------------------
# One of these is created for each known ESP32 myIOTDevice
# that is found with SSDP.  It maintains contact with the
# device, building it's state and managing communications
# between the myIOTServer and the device.
#
# Devices implement a "read-through" cache.
# Certain commands from the remote clients (i.e. value_list,
# and spiffs_list) return the current cached values from this server,
# which is aware of "set" commands from the devices as well.
#
# The key is that a given WSRemote socket can only (currently)
# be associated with a single local "device" (WSLocal) socket,
# though multiple such WSRemote sockets can exist.

package Pub::IOT::Device;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use Pub::Prefs;
use Pub::IOT::WSLocal;
use JSON;


my $dbg_device = 0;			# usual debugging where 0 == show, 1 == dont, -1,-2 more detail,
my $dbg_set_values = 1;		# if !$dbg_device, 0 == show set values, 1 == don't show

my $REOPEN_DEVICE_INTERVAL = 4;
	# seconds after we detect a closed socket
	# before we attempt to re-open it

# selected constants from C++ myIOT::myIOTTypes.h

my $VALUE_STYLE_NONE        = 0x0000;      # no special styling
my $VALUE_STYLE_READONLY    = 0x0001;      # Value may not be modified except by PROG
my $VALUE_STYLE_REQUIRED    = 0x0002;      # String item may not be blank
my $VALUE_STYLE_PASSWORD    = 0x0004;      # displayed as '********', protected in debugging, etc. Gets "retype" dialog in UI
my $VALUE_STYLE_TIME_SINCE  = 0x0008;      # ui shows '23 minutes ago' in addition to the time string
    # by convention, for hiding during debugging, password elements should be named with "_PASS" in them,
    # and the global define DEBUG_PASSWORDS implemented to ensure they are not, or are
    # displayed in LOGN calls.
my $VALUE_STYLE_VERIFY      = 0x0010;      # UI buttons will display a confirm dialog
my $VALUE_STYLE_LONG        = 0x0020;      # UI will show a long (rather than default 15ish) String Input Control
my $VALUE_STYLE_OFF_ZERO    = 0x0040;      # Allows 0 below min and displays it as "OFF"
my $VALUE_STYLE_RETAIN      = 0x0100;      # MQTT if published, will be "retained"
    # CAREFUL with the use of MQTT retained messages!!
    # They can only be cleared on the rpi with:
    #      sudo service mosquitto stop
    #      sudo rm /var/lib/mosquitto/mosquitto.db
    #      sudo service mosquitto start
    # or individually with
    #      mosquitto_pub -u myIOTClient -P 1234 -h localhost -t bilgeAlarm/ONBOARD_LED -n -r -d

my $VALUE_STYLE_HIST_TIME   = ($VALUE_STYLE_READONLY | $VALUE_STYLE_TIME_SINCE);




my $devices:shared = shared_clone({});


sub getDevices
{
	return $devices;
}


sub findDeviceByUUID
{
	my ($uuid) = @_;
	for my $device (values %$devices)
	{
		return $device if ($device->{uuid} eq $uuid)
	}
	return undef;
}

sub new
{
	my ($class,$uuid,$type,$version,$ip,$port) = @_;
	my $this = shared_clone({});

	$this->{uuid} = $uuid;
	$this->{type} = $type;
	$this->{version} = $version;
	$this->{ip} = $ip;
	$this->{port} = $port;

	# ws_ refers to the single open WSLocal socket
	# this server has to the device.

	$this->{ws_num} = 0;		   # opened
	$this->{ws_opening} = 0;	   # in process of opening
	$this->{ws_reopen_time} = 0;   # a delay between re-open attempts

	$this->{pending_local} = shared_clone([]);
	$this->{pending_remote} = shared_clone([]);
		# a queue of things to be sent (on the main thread)
		# to the device.

	$this->{cache} = shared_clone({});

	bless $this,$class;
	display($dbg_device,0,"new DEVICE($this->{type}) at $ip");
	display_hash($dbg_device+1,0,"DEVICE::new",$this);
	return $this;
}



sub onOpen
{
	my ($this,$ws_num) = @_;
	$this->{ws_num} = $ws_num;
	$this->{ws_opening} = 0;
	$this->{ws_reopen_time} = 0;
	$this->{pending_local} = shared_clone([]);
	$this->{pending_remote} ||= shared_clone([]);
		# the pending remote queue stays intact through local websocket close/opens
		# so that we can notify remote clients that the socket was lost or re-opened
	$this->writeRemote('{"ws_open":1}');
	warning($dbg_device,-1,"DEVICE($this->{type})::onOpen() pending_local=$this->{pending_local}");
}



sub onClose
{
	my ($this,$no_notify) = @_;
	warning($dbg_device,-1,"DEVICE($this->{type})::onClose()");
	$this->{ws_num} = 0;
	$this->{ws_opening} = 0;
	$this->{ws_reopen_time} = time();
	undef($this->{pending_local});	# = undef;
	undef($this->{pending_remote});	# = undef;
	$this->writeRemote('{"ws_open":0}') if !$no_notify;
}



sub add
{
	my ($rec) = @_;
	display($dbg_device+1,0,"SSDP called DEVICE::add($rec->{LOCATION})");

	my $uuid = $rec->{USN} && $rec->{USN} =~ /uuid:(.*?)(:|$)/ ? $1 : '';
	if (!$uuid)
	{
		error("DEVICE($rec->{LOCATION}) without UUID");
		return;
	}

	my ($type,$version);

	if ($rec->{SERVER} &&
		$rec->{SERVER} =~ /^myIOTDevice UPNP\/1.1 (.*)\/(.*)$/)
	{
		($type,$version) = ($1,$2);
	}
	if (!$type || !$version)
	{
		error("DEVICE($rec->{LOCATION}) without type or version");
		return;
	}
	if (!$rec->{ip} || !$rec->{port})
	{
		error("DEVICE($rec->{LOCATION}) without ip or port");
		return;
	}

	display($dbg_device+1,1,"checking LOCATION($rec->{LOCATION}) type($type) version($version) ip($rec->{ip}) port($rec->{port}) uuid($uuid)");

	my $skip_iot_types = getPref("SKIP_IOT_TYPES");
	if ($skip_iot_types && $type =~ /$skip_iot_types/)
	{
		warning($dbg_device+1,0,"SKIPPING IOT TYPE type($type) version($version) ip($rec->{ip}) port($rec->{port}) uuid($uuid)");
		return;
	}

	my $device = $devices->{$uuid};

	if (!$device)
	{
		$device = Pub::IOT::Device->new($uuid,$type,$version,$rec->{ip},$rec->{port});
		$devices->{$uuid} = $device;
	}
	else
	{
		display($dbg_device+1,0,"DEVICE $device->{type} at $device->{ip} already exists");
	}
}





sub loop
{
	for my $device (values %$devices)
	{
		# dispatch any pending writes to the device

		if ($device->{ws_num})
		{
			# pending_local should be set whenver ws_num is

			my $pending = shift @{$device->{pending_local}};
			while ($pending)
			{
				display($dbg_device,0,"DEVICE($device->{type}) dequeued: $pending from  pending_local=$device->{pending_local}");
				$device->_writeSocket($pending);
				$pending = shift @{$device->{pending_local}};
			}
		}

		# or, if not opened, open it

		elsif (!$device->{ws_opening} &&
			time() > $device->{ws_reopen_time} + $REOPEN_DEVICE_INTERVAL)
		{
			display($dbg_device,0,"handleDevices opening $device->{type}");
			$device->{ws_opening} = 1;

			if (Pub::IOT::WSLocal::open($device))
			{
				display($dbg_device+1,0,"device got ws_local #$device->{ws_num}");
			}
		}

	}	# for each device
}	# Pub::IOT::Device::loop()




sub _writeSocket
{
	my ($this,$msg) = @_;
	if ($this->{ws_num})
	{
		display($dbg_device,0,"DEVICE($this->{type}) _writeSocket($msg)");
		Pub::IOT::WSLocal::writeSocket($this->{ws_num},$msg);
	}
	else
	{
		error("No ws_num in writeSocket($this->{type},$msg)");
	}
}


sub writeLocal
{
	my ($this,$msg) = @_;
	# display($dbg_device,0,"DEVICE($this->{type}) writeLocal($msg) ws_num=$this->{ws_num}");
	# $this->_writeSocket($msg);
	# return;

	if ($this->{pending_local})
	{
		display($dbg_device,0,"DEVICE($this->{type}) writeLocal($msg) - add to pending_local=$this->{pending_local}");
		push @{$this->{pending_local}},$msg;
		display($dbg_device,0,"... after push pending_local=$this->{pending_local}");
	}
	else
	{
		error("no pending_local in writeLocal");
	}
}


sub writeRemote
{
	my ($this,$msg,$is_verbose) = @_;
	$is_verbose ||= 0;
	if ($this->{pending_remote})
	{
		if (1)
		{
			# display the first line of the message
			my @lines = split(/\n/,$msg);
			display($dbg_device+$is_verbose+1,0,"DEVICE::writeRemote($this->{ws_num}) length=".length($msg)." line=$lines[0]".(@lines>1?" ...":""));
		}

		display($dbg_device+1+$is_verbose,0,"DEVICE($this->{type}) writeRemote($msg)");
		push @{$this->{pending_remote}},$msg;
	}
	else
	{
		error("no pending_remote in writeRemote");
	}
}



sub onLocal
	# bytes received from the device
{
	my ($this,$msg) = @_;

	# print($msg);

	my $is_set = 0;
	my $is_verbose = 0;
	my $hash = decode_json($msg) || {};
	if ($hash->{set})
	{
		$is_set = 1;
		if ($this->{cache}->{values})
		{
			my $value = $this->{cache}->{values}->{$hash->{set}};
			if ($value)
			{
				$value->{value} = $hash->{value};
				# pass value of $dbg_set_values to write_remote,
				# usually NOT showing set value calls
				$is_verbose = $dbg_set_values;
				# previously was based on $VALUE_STYLE_VERBOSE
				# $is_verbose = $value->{style} & $VALUE_STYLE_VERBOSE ? 1 : 0;
			}
		}
	}

	if (1)
	{
		# display the first line of the message
		my @lines = split(/\n/,$msg);
		display($dbg_device+$is_verbose,0,"DEVICE::onLocal($this->{ws_num}) length=".length($msg)." line=$lines[0]".(@lines>1?" ...":""));
	}

	display($dbg_device+1+$is_verbose,0,"DEVICE::onLocal($this->{ws_num}) length=".length($msg));


	if ($is_set)
	{
		# case handled above before debugging
	}
	elsif ($hash->{booting})
	{
		$this->{booting} = 1;
	}

	# those that get merged and cached
	# display_hash(Device::onLocal(1))
	#   device_name = 'bilgeAlarm'
	#   device_type = 'bilgeAlarm'
	#   iot_setup = '1'
	#   iot_version = 'iot0.05'
	#   uptime = '459'
	#   uuid = '38323636-4558-4dda-9188-7c9ebd667ddc'
	#   version = 'iot0.05b0.05'
	# display_hash(Device::onLocal(1))
	#   dash_items = 'ARRAY(0x96f1ff4)'
	#   device_items = 'ARRAY(0x96f2074)'
	#   system_items = 'ARRAY(0x96f016c)'
	#   values = 'HASH(0x96f6c6c)'
	# display_hash(Device::onLocal(1))
	#   files = 'ARRAY(0x96f01cc)'
	#   total = '1374476'
	#   used = '598635'

	elsif ($hash->{device_name} ||
		   $hash->{values} ||
		   $hash->{spiffs_list} ||
		   $hash->{sdcard_list})
	{
		display_hash($dbg_device+1,0,"DEVICE::onLocal($this->{ws_num})",$hash);
			# note that this display_hash is only for certain hashes
		mergeHash($this->{cache},shared_clone($hash));
	}

	# everything from the device is passed to any connected remotes

	$this->writeRemote($msg,$is_verbose);

}




1;
