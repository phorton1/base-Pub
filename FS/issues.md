# Issues

## Cross Platform

At the moment there are many assumptions that Pub::Utils
is running on Windows.  Would want all the old unix stuff
and abillity to run servers (at least) on linux.

## Zipping

On Perl implementations it should be possible to transfer base64
encoded zip files,

SERVER --> WASSUP \t MACHINE_ID \t CAPABILITIES

## Basic Security

FS::Servers need Users and/or Password management,
and the protocol needs to change to sent them in
the HELLO.  WASSUP should probably return a
FULLY_QUALIFIED_SERVER_ID (MACHINE_ID) for local
servers, with / separators for inherited id's.

- A local fileServer should present itself as
  the windows machine name: i.e. LENOVO_3
- A teensySerialServer should now present itself
as a teensyExpression-SERIAL_NUMBER or TE-SERIAL_NUMBER
with no ZIP capabilities.


## Encryption and Security

Gets complicated quick.  First a quick look at Perl:

- FS::Servers should advertise themselves via SSDP
- For encryption Servers need to have, and know
  how to use SSL CRT and KEYs.
  - lord knows this will probably bring in thread/FORK issues.
- For internet access Servers would need to tunnel
  a port to my server in miami.

The old My::IOT::Server (rpi mostly uses a data_directory (home)
for prefs and can provide encrypted traffic using data_directory/ssl/
myIOT.CRT and myIOT.KEY.

In addition the old My::IOT::PortForwarder.pm uses the same ssl
directory to get myaiot_user_ssh.CRT and myaiot_user_ssh.KEY to
create a forwarded encrypted port on the server, which explicitly
sets a the users and passwords that can connect to SSH as myIOTuser,
There were issues with allowing passwords on Windows, and/or initial
setup using ssh-shell noticing a request to allow the new key.


### ESP32's

I believe ESP32's are too small to effectively support a full
SSL implementation.  Teensy certainly are.
- ESP32s myFileServers with connected STATIONS (or ETHERNET
  connections?!?) should advertse themselves via SSDP
  (or within the parent HTTPServer's SSDP for myIOT devices).
- myFileServers are always SerialServers?
- ESP32 myFileServers may also be TELNET/SSH servers

*Teensies *might* be able to do something similar with a
connected Wifi adaptor ?!? or over Ethernet ?!? but I
dread thinking about it*

Perhaps ESP32 myFileServers ARE myIOTDevices?
Remember big problems with trying to create secure webSockets on ESP32.


For security ESP32's need to be able to support SSH
	in addition to TELNET.
For fileServers, ESP32's need to present at least
    a fileServer port, but with security, a SSL
	compliant port.


Note the relation of the WEB_SOCKET_PORT=HTTP_PORT+1 in current
myIOT. myIOT C++ would need SHTTP for it's webserver, SSH instead
of TELNET, and implement secure WebSockets. Yech.

None of that would be remotely possible in FluidNC devices.

As for Perl, the old My::IOT::Server uses a data_directory (home)
for prefs and can provide encrypted traffic using data_directory/ssl/
myIOT.CRT and myIOT.KEY.

In addition the old My::IOT::PortForwarder.pm uses the same ssl
directory to get myaiot_user_ssh.CRT and myaiot_user_ssh.KEY to
create a forwarded encrypted port on the server, which explicitly
sets a the users and passwords that can connect to SSH as myIOTuser,

FS::Server would need the same ability to use SSL, and lord knows
that will probably bring in thread/FORK issues.

LOL, the ESP32 *could* concievably launch an actual IP::Port
to connect directly to it.





### SSDP

So we have this complicated case

- Any FS::Server available by PORT should advertise itself via SSDP
- The current myIOT device is a TELNET port, but we would need to
  get its SSDP descriptors to do a better job of really getting its
  TELNET port, and sub-devices it might have like, a FS::Server.
- Porting teensyExpression2::fileSystem to ESP32 will be problematic,
  as will be using it from the current myIOT Serial handler.

### Arduino-libraries-SerialFileServer

Factored from teensyExpression2 fileSystem.cpp fileCommand.cpp and parts of theSystem.cpp

ESP32s would need to start the Server and do threads of some sort.
Of course, it would only work if there was an SDCard, which is
it's own complication, esp allowing for removability.

For myIOT, besides starting the Server and somehow emulating teensyThreads,
myIOTSerial() would need to look for file_commands and file_messages
and pass them to the SerialFileServer instead of myIOTDevice::handleCommand()
as it currently does.

FluidNC would be terribly complicated.


**HTTP port and SSDP** (in myIOTHTTP.cpp)

The whole CaptivePortal scheme likely depends on the use of port 80.
I don't know if that gets passed as the 'Device Webpage' as shown
in Windows Explorer, etc.  Does not seem that unreasonable that a
simple single ESP32 has a fixed port 80 for HTTP and 23 for TELNET,
and would have a fixed DEFAULT_SOCKET_PORT 5872 for a FS::Server.


**Serial and Telnet processing** (in myIOTSerial.cpp)

The current use of ESPTelnet onInputReceived works in the
default ESP32::telnet _line_mode, which returns on \n and
strips all but chr(32)..chr(127) from the string. Thus there
are no embedded tabs or cr's, both of which are needed
for a C++ SerialFileServer. We would need to replace
onInputReceived(String) with onInput(String) which would build
our own lines of text.

Serial.isAvailable() currently strips out crs,
which is also already done in myIOTDevice::handleCommand()

