# Details and Abstractions

## SERVER_ID

- local FC::Pane ==> LENOVO_3
- local fileServer on my machine ==> SERVER/LENOVO_3
- teensyExpression SerialServer ==> TE_SERIAL_NUM (not directlly accessible)
- buddy's BridgeServer ro teensyExpression ==> BRIDGE/TE_SERIAL_NUM

- myIOTDevice ==> user defined DEVICE_NAME-MAC_ADDRESS
- BridgeServer to myIOTDevice ==> BRIDGE/DEVICE_NAME-MAC_ADDRESS
- BridgeServer via Telnet to myIOTDevice ==> TELNET/DEVICE_NAME-MAC_ADDRESS

The last term uniquely identifies an actual file sytem and is known
as the MACHINE_ID


## Concepts

A **Connection** is between two **Sessions**.

- a *Connection* defines everything necessary to present a *Window*
  in the fileClient.
- has **connection_id**, which is also used as the label for the tab
  for the Window in fileClient.
- has two **session_ids** that specify the two *Panes* that will be
  presented in the Window.
- has two **dirs** that specify the starting directories for
  each of the panes.

A *Session*

- defines everything necessary to present one of the two *Panes* within
  a Window.
- has a *session_id*
- has a **dir** used in the event that there is none specified by a Connection.
- specifies a **port** to connect to.
- if no port is specified, the **local file system** is used.
- specifies a **host** to use when *port* is specified.
  if no host is specified **localhost** is used.

Sessions that connect to a *port* are sometimes called *remote sessions*.

The **local** file sytem is special.

- **local** can be used as a session_id
- there is a system wide **default_local_dir** for the local file system
  in case one is not specified by a Connection or Session.


### Starting Directories

In addition to the *default_local_dir* for the local file system,
there will be a system-wide **default_start_dir** for any Sessions
that define a *port*. to connect to, to be used if none is specified
for a given Session.

The default_local_dir and default_start_dir must be *fully
qualified* ... that is, they **must** start with a forward slash ('/').

Other starting dirs may be fully qualified (starting with '/')
or they may be partially qualified, relative to the default dirs.


## Command Line

fileClient may be run with no command line parameters, allowing the user to
choose defined Connections to open windows, along with any UI necessary to
create and edit Connections, Sessions, Servers, and default Preferences.

The use of any command line parameters overrides the function of any
global preferences that have to do with how the program starts up.
In other words, passing anything on the command line will prevent the
*restore_windows_at_startup* preference from having any effect.

The command line allows the user to open a single Window, by specifying
a Connection or two Sessions.

	fileClient -c connection_id
	fileClient -s session_id -s session_id.

If only one Session, or part of one, is specified on the command
line, a second **local** Session will be assumed.

When used with Sessions, the command line can include a temporary
*connection_id* to be shown as the name of the tab, by using the **-cid**
parameter. If *-cid* is not is present, fileClient will make up a name
for the tab.

	fileClient -cid MyWindow -s session_id -s session_id.

The order of the parameters is important. The first Session specified
will show up in the left Pane, and the second one in the right Pane.

Likewise, the command line can be used to *build* temporary Sessions in
whatever level of detail is required by passing **-sid** , **-d "dir"**,
**-p port**, and **-h host** parameters, alone, or **after** any *-s*,
as desired.

It is importan to understand that any re-specification of the same parameter
on the command line already used for the first session starts the definition
of the second session. This was implicit in specifying -s session_id twice,
but is more subtle when parts of sessions are specified on the command line.

For example, the following command line specifies the first Session using
a **-h host** parameter with an implicit *port*. The **-p port** parameter
starts the second specification with a connection to *localhost*, and the
**-d dir** applies to it.

	fileClient -h 192.168.0.123:5872 -p 5872 -d "/junk"

On the other hand, details *within* a session specification are grouped together
within higher level concepts as long as they are not repeatedly specified.

	fileClient -s session_id1 -d "/junk" -session_id2 -p 8383

The above example tells the program to load session_id1 and session_id2, using
"/junk" as the starting dir for Pane1 and the port 8383 to override the one
specified in the Session given by session_id2. Assumptions have to be made, so
the system will make up a temporary *connection_id* for the tab name, and if a
*host* is not specified in Session2, then it will assume the use of **localhost**
since it now has a port number.


### Command Line Paramters Fully Defined

The full list of command line parameters is given here

- -c connection_id
- -cid temporary_connection_id
- -s session_id
- -sid temporary_session_id
- -d starting dir, quoted if it contains spaces
- -h host name or ip address (with optional port included)
- -p port number
- -M (uppercase) MACHINE_ID, with wild cards, to search for


**-M** require a little further explanation. A Pane *remembers* the SERVER_ID
which contains the MACHINE_ID that correlates to specific machine and it's
local file system, once it connects. Like -s, *-M* constitute an entire Session/Pane
specifier. The system will search through all existing Sessions, which can be
put in a preferential order by the user, and will select the first session that
matches the given MACHINE_ID, using leading or trailing asterisks *'* as wildcards.

	fileClient -s local -M TE*
		// Will open the left Pane to the local file system (using the
		// default_local_dir), and search for a Session to open in the
		// right Pane.  The -M will match any Sessions that have previously
		// connected to a MACHINE_ID that starts with TE.  This would match any
		// teensyExpressions because they have a MACHINE_ID of TE, followed
		// by a serial number.


### Command line from Buddy

The command line from buddy will look something like this:

	fileClient -s local -p 12345

The above command will open the local file system in the left Pane, using the
*default_local_dir* from the preferences, and a connection to localhost:12345,
which will be buddy's serial BridgeServer (to the teensyExprssion) which will
end up returning a server id like BRIDGE/TE000XXX. The right Pane will start
at the *default_start_dir*.

I have yet to Determine what the default names of Panes will look like.


## fileclient Preferences

- Preferences
  - restore_windows_at_startup
    - means whether to save and restore from an INI file
	- note that the INI file is ONLY read/written if no command
	  line parameters are given.
  - default_local_dir
  - default_start_dir
  - Connections
  - Sessions
- Connection
  - **connection_id** (tab_name)
  - auto_start if no command line parameters and not restore_windows_at_startup
  - session_id1 or **local**
    - start_dir1
  - session_id2 or **local**
    - start_dir2
- Session
  - **session_id** (shown before SERVER_ID in UI)
  - start_dir
  - port, where blank means the *local fie system*
  - host to use if port specified, and blank means *localhost*
  - *remembers* SERVER_ID if it connects



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
