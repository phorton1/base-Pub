# Implementation

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
