# Implementation

**Issues**

- Basic Security
- Encryption, , and the Internet
- zipping
- The "could not get directory" issue
- Synchronizing across multiple connections, processes, and machines
- fileClient Preferences & Connections UI

## Cross Platform

At the moment there are many assumptions that Pub::Utils
is running on Windows.

## SERVER_ID

- local FC::Pane ==> LENOVO_3-PRH

- local fileServer on my machine ==> SERVER/LENOVO_3-PRH

- myIOTDevice ==> user defined DEVICE_NAME-MAC_ADDRESS
- teensyExpression SerialServer ==> TE_SERIAL_NUM

- buddy's BridgeServer ==> LENOVO_3/COM3/TE_SERIAL_NUM
- BridgeServer to myIOTDevice ==> LENOVO_3/COM8/DEVICE_NAME-MAC_ADDRESS
- BridgeServer via Telnet to myIOTDevice ==> LENOVO_3/TELNET/DEVICE_NAME-MAC_ADDRESS

The last term uniquely identifies an actual file sytem and
is known as the MACHINE_ID


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


## Zipping

On Perl implementations it should be possible to transfer base64
encoded zip files,

## Could not get directory Issue

The simple "the other window deleted or renamed part of my dir"
issue could be solved within a single process using the current
direct calling method of updating "same" panes by port number.

We need a solution, perhaps trying successive children directories,
or the default directory, when this legitimately happens.




## Synchronization

I added some simple code to the Pane that if the OtherPane has the
same {port} number, and is pointing to the same {dir} changes to the
Pane will cause the OtherPane to update its contents by calling its
setContents() and populate() methods.

Similar code could be written to notice when a subdirectory
of the OtherPane goes away or is renamed, and to position the
OtherPane at the last common ancestor.

It would be fairly easy to do that accross multiple windows in the
same program instance that have the same conditions, but it may
want to be done through a "pending update" method so that it is
put off until the given Window is shown.



### Synchronization across processes and connections

A thornier issue is doing that between multiple invocations of the
fileClient on a given machine, and ultimately, across connections.

The amounts to creating a whole change notification system where
clients and servers know the "machine identifier" like "LENOVO 3"
or perhaps "LENOVO 3 - Com3 - TeensySerialServer" they are attached
to, noice changes, and notify any connected clients, with the noted
issue that there could even be multiple Servers running on the same
machine referencing the same local file system.

This goes to the path displayed for a Pane and/or the name of the Window,
and plays into the complicated as-yet-undesigned general fileClient
Connection/Preferences UI, as well as the "could not get directory" issue.

Remember that there is no Server for the base local Session!

SERVER <-- HELLO
SERVER --> WASSUP \t MACHINE_ID \t CAPABILITIES



## Preferences & Connection UI

I havn't quite got my head around this yet. I envision:

Note that buddy currently contains the "auto" connect ideas.

- fileClient (with no params?!?) as having a completely
generalized method of specifying what connections are made and
how they are grouped into Panes
- fileClient allowing user-level parameters to create multiple
shortcuts to open certain Window/Connections at startup
(in addition to the current magic PORT passed in by buddy)

In fact, the current magic PORT does not allow them to
specify the starting directories, much less on a per
'Connection' basis.

Preferences require a DATA directory.
Some ideas require INI files

### buddy

**Params**:

-auto
-auto_no_remote ==> auto
-rpi
-crlf
-arduino
-file_server
-file_client  ==> file_server
-BAUD_RATE
-IP_ADDRESS[:PORT] ==> crlf

**Current Auto Stuff** uses ComPorts and SSDPScan in
precedence order:

- $port->{midi_name} eq "teensyExpressionv2" ==> -port -arduino -file_server
- $port->{device} implies 'Arduino' ==> -port -arduino
  - port->{device} =~ /ESP32/ ==> -crlf
- myIOTDevice found ==> IP_ADDRES:DEFAULT_SOCKET_PORT
- $port ==> -port

The use of DEFAULT_SOCKET_PORT above is wrong because it is a
Telnet session that buddy is connecting to. buddy could conceivably
start a serial BridgeServer to it.

On the other hand, if the SSDP device is a Server (a fileServer
or, currently, running it's own BridgeServer), then fileClient
should be able to connect directly the SSDP device without
involving buddy,

So there DEFAULT_SOCKET_PORT is wrong, should at least be
DEFAULT_TELNET_PORT, and really needs to be given to buddy
by the SSDP device.


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



### fileclient Preferences

- Preferences
  - default_start_folder
  - default_connection_id
  - default_start_in_last_folder (requires INI file)
  - auto_start_default_connection
  - Sessions
  - Connections

- Session
  - **id** (name)
	- reserved **id** **local**
  - start_in_last_folder
    - default_start_in_last_folder
	- true
	- false
  - start_folder
	- default_start_folder
	- explict
  - for **id** != local
    - HOST
	  - localhost
	  - IP address with auto searching
	    - means SERVERs are SSDP devices
	- PORT
	  - DEFAULT_FS_PORT
	  - specific_number
	  - *from_command_line*

- Connection
  - **id** (name)
  - session1_id
  - session2_id

### Command Line Parameters

-connection connection_id
-session session_id [-session session_id]

-local -
-port {}

### Servers with SSDP and MACHINE_IDs







# Implementation Architecture

The implementation, particularly the doCommand heirarchy,
closely mimics the Protocol.


- **FC::Pane**
  - creates a base *FS::Session* for local panes
  - creates a *FC::ThreadedSession* for remote panes

- **Server**
  - creates *ServerSession* by default
  - implements processPacket() to parse packets to parms and entries and call $session->doCommand()
  - is progress-like
    - implements aborted() to call getPacket() to see if an abort has been issued
	- implements addDirsAndFiles, setEntry, and setDone, to send packets
  - **fileServer** is a vanilla *Server* executable program
	- has while (1) {sleep(10;)} wait loop
  - **SerialBridge** - instantiated by **buddy**
    - creates *SerialSessions*
	- implements processPacket() to pass unchanged packets to SerialSession::doSerialRequest()

- **Sesssion**
  - implements doCommand() and _list(), _mkdir(), _rename(), _delete() for local file system
  - returns *FileInfo* objects or reports errors and returns blank
  - calls $progress methods
  - **SocketSession**
    - adds SOCK member and implements sendPacket() and getPacket()
    - **ServerSession**
	  - implements doCommand() to call base class and convert FileInfo objects or error messages
	    to packets that it sends back to the connected client
	  - Thus it always terminate with a FileInfo packet, or an ERROR or ABORTED text packet
	- **SerialSession**
	  - implements doSerialRequest() which serializes requests (packets) and sends them
	    over the COM port (via buddy) to the teensy (SerialServer)
		- waits for terminal serialized reply to end the request
		- checks the socket for ABORT packets from the client which it forwards
		  as an out-of-band serial_request to the teensy (SerialServer)
		- returns PROGRESS serial_replies it receives back to the client over the socket.
		- Thus, at this time, it passes all serial_replies it receives, unchanged,
		  back over the socket to the client
	- **ClientSession**
	  - implements connect(), disconnect(), and isConnected() methods
	  - implements doCommand() and _atoms to convert commands into packets that it sends
	    over the socket to a Server
 	    - convert packets it recieves into FileInfo objects that it
		  it returns to the client (FC::Pane).
	    - _delete() implements a synchronous getPacket()-until-not-PROGRESS loop that
	      calls $progress (whatever it is) methods until a terminal packet is received
	  - **FC::ThreadedSession**
	    - is intimately knowledgable about FC::Pane and even contains FC::Pane method implementations
		  for onThreadedEvent() and onIdle()
	    - implements doCommand() to wrap ClientSession::doCommand() in a WX::thread to avoid blocking the UI thread
			- returns -2 immediately to the FC::Pane callers who know to bail on threaded commands
			- sets $pane->{thread} to prevent re-entry invocations of commands while in a threaded command
		    - calls doCommandThreaded() which waits for terminal result from ClientSession::doCommand()
		      and posts a massaged $THREAD_EVENT for for the terminal result
		- implements progress-like methods to be called by ClientSession::doCommand() atoms
		  which in turn post PROGRESS $THREAD_EVENTS
		- onThreadedEvent() recieves $THREAD_EVENTS
		  - calls ui $progress methods for PROGRESS events
		  - knows how to finish FC::Pane operations that were suspended for
		    threaded commands upon receiving terminal events


### FC::Pane

Instantiates a base class **FS::Session** for *local* panes and a
**FC::ThreadedSession** for *'remote'* panes.

Orthogonally callls **$session-doCommand()** with added *$caller*
parameter which is ignored by base class session.

Local commands are handled directly by the *FS::Session*, with
asynchronous commands directly updating the $progress window along
the way, while checking for $progress->aborted().

*FC::ThreadedSession::doCommand()* returns -2 to indicate that
a threaded command is underway, and callers bail on whatever they
were doing.  The *$pane->{thread}* member is set to prevent
any re-entrancy.  **onThreadEvent()** updates the $pane->{progress}
upon PROGRESS events and knows how to finish, upon terminal events,
the commands that were in progress based on the *$caller* parameter.

A special case threaded caller is **setContents** which may be
called terminally with a **-1** to indicate that it should
*disable* the window and display a red **could not get dirctory**
message to the user.


### FC::ThreadedSession::doCommand()

FC::ThreadedSession::doCommand() uses *Perl threads and WX::Events*
  to implement the non-blocking doCommandThreaded() method

See: https://metacpan.org/dist/Wx/view/lib/Wx/Thread.pod

### teensyExpression

teensyExpression C++ uses *teensyThreads* to handle multiple
  concurrent *serialized file_commands*.

- theSystem.cpp new's a buffer for each serialized file_command
  as it comes in, and when ready (\n is received) starts a
  a *thread* to call fileSystem.cpp fileCommand().
- the thread de-serializes the packet, and sends one or
  more *serialized file_replies* to the serial port for PROGRESS
  updates and terminating with a DIR_LIST/FILE_ENTRY, ABORTED, or
  ERROR file_reply
- a second out-of-band same-serial_number ABORT message can be
  sent to the teensy which will buffer it, start a fileCommand()
  thread for it, which will then set a flag that the prior fileCommand()
  can see so it can terminate the command and return ABORTED.

PRH: Note that there is currently nothing to stop intermingling
of file_replies generated by fileSystem.cpp.  It needs
a **semaphore** to ensure that full file_replies (with
file_reply_end) are sent out at a time.


### Aborting doCommandThreaded()

Aborting a remote_request started by doCommandThreaded() is
complicated enough that it warrants a more detailed description.

*Using DELETE over the SerialBridge as an example*

The key is that SerialSession::doSerialRequest is tied to a
particular FC::Pane/Window by the thread doSerialRequest() is running
in (as there is only one thread/socket per FC::Pane).

- FC::Pane::onIdle() checks if a threaded command
  ($pane->{thread} is set) is being aborted by calling
  $pane->{progress}->aborted().
- if $pane->{progress}->aborted() it sends one ABORT packet
  via it's ThreadedSession (which is a ClientSession which is
  a SocketSession), $pane->{session}->sendPacket("ABORT").
- The connected SerialSession is presumably in the middle
  of a serialized doSerialRequest() wait loop.
- The wait loop recieves the ABORT packet, serializes it
  and sends it as an out-of-band same-serial-number file_command
  to the teensy.
- the teensy buffers the same-serial-number ABORT packet and
  starts a new threaded fileCommand() for it.
- the fileCommand(ABORT) sets a flag that the serial_number
  command has been aborted and short returns.
- the previous fileCommand() for the serial number notices
  the ABORT message, ceases it's operation, and sends a terminal
  ABORTED serialized file_reply.
- The SerialSession::doSerialRequest() wait loop terminates
  sending the ABORTED packet back over the socket to the
  ThreadedSession (ClientSession::_delete()) command which
  terminates, returning the ABORTED message to
  ThreadedSession::doCommandThreaded()
- ThreadedSession::doCommandThreaded() posts a $THREAD_EVENT
  with the terminating ABORTED message and returns.
- FC::onThreadEvent() receives the ABORT message and displays
  it in a dialog box to the user, then terminates whatever
  FC::Pane command was in progress (by calling setContents
  and populate to refresh the pane)
