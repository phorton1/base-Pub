# Protocol General

*This readme describes the current implemetation where the fileClient
only connects to buddy, and the fileClientWindow knows that pane1
is local and pane2 is a connection to buddy's RemoteServer.*

*In the future I envision allowing the user to determine what
each pane connects to, with appropriate optimizations, so that,
for instance, you could have two panes connected to the same
remote Server, and XFER files between panes (including Copy
and Paste) and the actual work would all be accomplished on
the remote Server with only PROGRESS notifications being sent
back to the fileClient.*


### All Packets

Packets are also referred to as *messages* in this document.

Packets are plain ASCII text that may contain multiple *lines*
delimited by carriage returns (\r) and which are terminated
with a crlf (\r\n).

The main protocol packets are as follows. *Uppercase words*
are part of the protocol and appear as shown in the packets.
The first *word* is sometimes referred to as the packet *type*
or the *verb*.  The *lowercase words* are *parameters* that
depend on the packet type.

- HELLO
- WASSUP
- EXIT
- ENABLED 		- msg
- DISABLED 		- msg
- ERROR			- msg
- LIST			dir
- MKDIR			dir name
- RENAME		dir name1 name2
- ABORT
- ABORTED
- PROGRESS		ADD 	num_dirs num_files
- PROGRESS		DONE 	is_dir
- PROGRESS		ENTRY 	entry
- PROGRESS      SIZE    size
- PROGRESS      BYTES   bytes
- DELETE		dir (single_filename | entry_list]
- XFER			is_local dir target_dir [name | entry_list]
- GET           dir filename
- PUT			dir filename
- BASE64		offset bytes checksum contents
- CONTINUE
- XFER_DONE


The delimiter for fields in packet lines
is a tab "\t", with the exception of the single line ERROR packet
which uses "space dash space" as the delimter.

The *dir* and *target_dir* parameters in the above packets
are always **fully qualified paths** and the other parameters
(name, name1, name2, and the *entry_list* items) are *leaf names*
within the fully qualified dir path.

Packets that use *entry_lists* are muliple lines with the first
line contain the command and listed parameters, always including a
fully qualified *dir* parameter, with subsequent lines containing *entries*
which are \t delimited representations of FileInfo object (files and/or subdirs)
that utilize only *leaf names within* the dir given by the first line.

In addition to the above packets which explicitly start with a protocol
*verb*, *reply packets* can merely consist of a text representation of a
FileInfo object, either a *DIR_LIST* with *entries*, or a single
*FILE_ENTRY*. In the case of a DIR_LIST, the main entry itself
may or **may or may not** be *fully qualified*, depending on the
context, but all it's entries are always leaf names relative to
the main entry.  A FILE_ENTRY is always the leaf name of
an object within the dir, whether it is a *filename* within that
dir, or the name of a *sub directory* within the dir.

In this document the words *DIR_LIST* and *FILE_ENTRY* are
used to describe these types of reply packets, but those words
themselves are NOT part of the protocol.


### Session Connection

A Session is initiated by a client after successfully
connecting to a remote *socket* and sending HELLO.
The Server replies with WASSUP to indicate it is ready
to start receiving packets:

- CLIENT --> HELLO
- SERVER <-- HELLO
- SERVER --> WASSUP
- CLIENT <-- WASSUP

Either the client or the server consider the Session to be
irretrievably 'lost' (dead) if a call to *sendPacket()* fails (which
apparently never happens), or a call to **getPacket()** *times out* or
receives a *null (empty) reply* (which is the typical failure mode).
In either case the caller invalidates the Session (by setting the
*SOCK* member of the Session to NULL) and ceases to call sendPacket()
or getPacket() further within that Session until a new connection
(socket) is established.

An invalid Session is also referred to as a a *lost socket* in
this discussion.

A Server invariantly exits the thread associated with the lost
socket, but it is upto the fileClientPane/Window to decide what to
do if it detects a lost socket. The fileClientWindow currently
closes itself on a lost socket, and, if it is the last window,
currently closes the fileClient application.

This is opposed to an explicit user Disconnect command in the
current implementation of the remote fileClientPane, in which case
the fileClientWindow remains open, with the remote pane disabled and a
message of "Socket Connection Lost" displayed to the user,
The current implementation allows the user to Reconnect by right
clicking in the (still enabled) local pane.

*I envision, in the future, the fileClient to be runnable as it's
own stand alone application, the difference being that in that case
it would not receive an ARGV containing a port number as a command
line argument, and would not automatically shut down on closing the
last window and would need to allow a pane to be disabled and still
allow access to the Reconnect command  (probably implemented by moving
adding a subclasses onContextMenu() method to the clientWindow).*


### EXIT

- Sent by clients, like the fileClientPane, when they are done with a connection
- Sent by servers, like the RemoteServer in buddy, when the server is shutting down

*Following is a description of the current implementation.*

For example, when the user closes a fileClientWindow, the window sends an EXIT
message to buddy's RemoteServer with a slight delay before closing it's own socket.
The delay allows the packet to be sent before the socket is closed. The received EXIT
allows the Server to free up the thread and any memory associated with the connection.

Or vice-versa, when buddy shuts down the RemoteServer, as each thread terminates,
it sends an EXIT message to the associated fileClientWindow (again with a small
delay before it closes the socket), and the fileClientWindow knows to close itself.

In either case the recipient of the EXIT message knows not to send another
EXIT message back to the sender of the first EXIT message.


### Asynchronous Messages

- ENABLE - msg
- DISABLE - msg

Asynchronous messages can be sent from a Server to the connected client
at any time, including while in the middle of executing a command.
These are currently sent from buddy to all connected fileClientWindows
when the COM_PORT goes offline or comes online, ie:

	DISABLE - Arduino Build Started
	DISABLE - Connection to COM3 lost
	ENABLE  - COM3 Connected

Note that ENABLE and DISABLE use " - " (space dash space) as the
delimiter between the verb and the message parameter.

### ERROR

Any command can terminate in an ERROR message.

Regardless of the configuration, ERROR messages are ultimately
sent to the fileClientPane that is executing the command,
and reported to the user in a dialog box.

Note that ERROR uses " - " (space dash space) as the
delimiter between the verb and the message parameter.



### Synchronous Commands

- LIST			dir
- MKDIR			dir name
- RENAME		dir name1 name2
- DELETE		single_filename

These commands take place in a single atomic operation
with a DIR_LIST or FILE_ENTRY being returned.  All of
the above return a DIR_LIST upon success except RENAME
which returns a FILE_ENTRY as the fileClientPane is optimized
to update the UI only for the changed filename in that case.

Implementation-wise, however, remote commands are threaded in
the WX remote panes, so they are really asynchronous. So
care needed to be taken to prevent another command from being
initiated in the fileClientWindow while a threaded remote command
is under way in a remote pane.


# Command Sessions

The XFER and 'DELETE entry_list' commands are asynchronous in nature
and have a delimited lifetime.

The DELETE is finished when the client receives a DIR_LIST reply.
XFER is completed when the client receives an XFER_DONE message.

PROGRESS gives the client information to update a progress dialog.

	PROGRESS ADD	num_dirs num_files  // adds dirs and files to progress range
	PROGRESS DONE   is_dir              // increments num_done for dirs and files
	PROGRESS ENTRY  entry               // displays the path or filename. hides the 2nd gauge if shown
	PROGRESS SIZE   size/               // start showing the 2nd 'bytes transferred' gauge
	PROGRESS BYTES  bytes               // set the value for the 2nd bytes transferred gauge

ABORT can be sent by the client to stop an operation in progress, in
which case the server returns ABORTED to acknowledge the cessation
has taken place.

Implementing the ABORT between the SessionRemote and teensyExpression's
handleSerial() method is complicated.


## DELETE dir entries

Client waits for a DIR_LIST indicating the operation is complete,
while looking for ABORT and processing PROGRESS messages.

Server sends PROGRESS messages as it recurses new directories
and counts their entries, and per each item deleted.


## Command Session implementation details

*This info does not properly belong in the Protocol.md readme file*

- teensyExpression C++ uses *teensyThreads* to handle multiple
  simultaneous Serial file_requests
- fileClientPane.pm uses *Perl threads and WX::Events* to
  implement non-blocking doCommandThreaded() method

### teensyExpression

- SessionRemote *blocks* until the serial port is available
  for new requests, so only one request at a time is sent
  to the teensy serial port.
- theSystem.cpp new's a buffer for each serial request as
  it comes in, and when ready (\n is received) starts a
  a *thread* to call fileSystem.cpp handleFileCommand().
- the thread sends one or more *file_replies* to the
  serial port.
- there is currently nothing to stop intermingling of
  file_replies generated by fileSystem.cpp.  It needs
  a **semaphore** which can just be a memory variable

### fileClientPane

See: https://metacpan.org/dist/Wx/view/lib/Wx/Thread.pod

- for remote commands, the fileClientPane creates a
  *Perl thread* to call the regular Session::doCommand(),
  thus preventing the system from blocking on a paricular
  getPacket() call.
- when doing so, it sets fileClientWindow->{thread} as
  a flag to prevent the window or panes from re-entering
  a subsequent command, double clicking, sorting, or
  basically doing anything in either pane, while not
  explicitly disabling it.


### Aborting doCommandThreaded()

*Using DELETE remote as an example*

**Command Initiation**

- fileClientPane::doCommandSelected() builds a list of entries for
  the DELETE and calls it's doCommand() method.
- fileClientPane::doCommand() notices that it is a remote
  comand and starts a thread for fileClientPane::doCommandThreaded().
  - It sets fileClientWindow->{thread} to prevent any other commands
    in either pane from occurring.
  - fileClientPane::doCommand() returns a special value of -2 immediately.
  - fileClientPane::doCommandSelected() notices the special -2 value
    and returns immediately without further updates to the UI.
- doCommandThreaded() calls Session::doCommand(DELETE.!is_local)
  and waits for it to return.
- Session::doCommand(DELETE,!is_local) calls its _deleteRemote()
  method which sends the command packet to the RemoteServer
- The RemoteServer base Server class notices that it IS_REMOTE
  and that the command is DELETE and calls the RemoteSession's
  optimized deleteRemotePacket() method.
- RemoteSession::deleteRemotePacket() calls RemoteSession::doRemoteRequest()
  to send the packet as a **numbered file_request** to the teensy.
- teensyExpression theSystem.cpp buffers the *serial request* and
  starts a teensyThread to call fileSystem.cpp's handleFileCommand() method
- handleFileCommand() parses the packet to get the **request number**
  and list of **entries** and starts iterating over the entries,
  sending serial numbered PROGRESS file_replies until it finishes and
  sending a final serial numbered ERROR or DIR_LIST file reply when it
  is done.

**Wait Loops** after Command Initiation

- the original (threaded) Session::_deleteRemote() method loops, calling
  getPacket(1), until it gets a non-progress packet.
  - For each PROGRESS packet it gets, it calls the appropriate
    addDirsAndFiles(), setEntry(), or setDone() method on the
	$progress object it was passed.
- SessionRemote::doRemoteRequest() loops, waiting for numbered
  file_replies until it gets one that is not a PROGRESS message.
  It sends **any and all** file_replies it recieves back through
  the socket to the Session::_deleteRemote() loop,
  including PROGRESS messages.

**PROGRESS messages** from the teensy back to the fileProgressDialog()

*SessionRemote::doRemoteRequest() uses a method called waitReply()
which is an implementation detail and not specifically described herein.*

- the teensy sends a serial numbered PROGRESS file_reply to buddy.
- buddy demultiplexes the request_number and effectively passes
  the packet to the correct instance of SessionRemote::doRemoteRequest()
- SessionRemote::doRemoteRequest() sends the PROGRESS packet over the
  socket to the threaded Session::_deleteRemote()
- Session::_deleteRemote() calls a $progress method, i.e. setEntry()
- The fileClientPane has implemented methods to look like a
  fileProgressDialog(), so it's setEntry() method is called.
- fileClientPane::setEntry() posts a pending Wx $THREAD_EVENT
  as the thread cannot access the UI directly
- fileClientPane::onThreadEvent() receives the PROGRESS
  message and calls $this->{progress}->setEntry() to
  send the entry to the actual fileProgressDialog()

**Command Termination**

- the teensy sends a final numbered ERROR or DIR_LIST
  file_reply to buddy, which demultiplexes it to the
  correct instance of SessionRemote::doRemoteRequest()
- SessionRemote::doRemoteRequest() sends the packet over the
  socket to Session::_deleteRemote() and returns
- SessionRemote::deleteRemotePacket() returns,
  returning control back to the RemoteServer/Server
  sessionThread().
- The original (threaded) Session::_deleteRemote
  recieves the terminating packet, decodes it an
  actual FileInfo (is_dir=1) if the packet is a DIR_LIST.
- Session::doCommand() returns the decoded packet to
  fileClienPane::doCommandThreaded()
- fileClientPane::doCommandThreaded() posts a pending
  Wx $THREAD_EVENT with the decoded packet as 'data',
  as the thread cannot access the UI directly.
  doCommandThreaded() does some trickery, adding a {caller}
  method and creating a shared hash to return if needed, if
    - the decoded packet is a DIR_LIST
	- it the command was RENAME and there was an error,
	- there was empty packet returned
- fileClientPane::onThreadEvent() receives the terminating
  packet and 'finishes' the particular command (given by
  the 'caller' member on the data) in an appropriate manner.
  For DELETE this means calling error() for any ERRORS and
  calling setContents() with the DIR_LIST or null, followed
  by populate().

## HOW ABORT WORKS

The key is that SessionRemote::doRemoteRequest is tied to a particular
fileClientPane/Window by thread doRemoteRequest() is running
in (as there is only one thread/socket per remove fileClientPane).

- fileClientPane::onIdle() checks if a threaded command
  ($this->{parent}->{thread}) is being aborted ($this->{progress}
  && $this->{progress_aborted}) and if so, send one ABORT packet
  to the SessionRemote (using new $override_protocol parameter
  to sendPacket).
- SessionRemote::doRemoteRequest(), which is looping waiting for
  file_replies from the teensy calls getPacket(0) to see if any
  ABORT packet has arrived without blocking. Remember that
  sessionThread is no longer blocking on a packet as that thread is
  now executing doRemoteRequest(), and no other client process
  should be sending more packets to the SOCKET due to re-entrancy
  protection in fileClientPane/Window.
- If SessionRemote::doRemoteRequest() receives an ABORT packet,
  it will issue a SECOND file_request with the SAME REQUEST
  NUMBER for the ABORT.
- teensyExpression theSystem.cpp will receive the 2nd request
  and start another threaded handleFileCommand.
- the second handleFileCommand(ABORT) will call addRequstAborted(req_num)
  to add the request number to an array of pending_aborts, and return.

Meanwhile the original handleFileCommand(DELETE) will be calling
the new checkRequestAborted(req_num) method which will check the array,
and return true if the req_num for the DELETE is in the array,
which will cause the handleFileCommand(DELETE) to send a serial
ABORTED numbered file_reply and terminate.  handleFileCommand()
will call clearRequestAborted(req_num) as it leaves to keep
the array compact.

The ABORTED message is passed back up the chain until it is
returned by a WX $THREAD_EVENT to onThreadEvent() which will
generate the okDialog, close the $progress window, and call
setContents() and populate() to fix things up.

