# Protocol

**and some implementation details**

*This readme describes the current implemetation where the fileClient
only connects to buddy, and the FC::Window knows that pane1
is local and pane2 is a connection to buddy's SerialBridge.*

*In the future I envision allowing the user to determine what
each pane connects to, with appropriate optimizations, so that,
for instance, you could have two panes connected to the same
remote Server, and XFER files between panes (including Copy
and Paste) and the actual work would all be accomplished on
the remote Server with only PROGRESS notifications being sent
back to the fileClient.*


### All Packets

Packets are also variously referred to as *messages*, *commands*,
*requests*, and/or *replies* in this document.

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


### DIR_LIST and DIR_ENTRY

In addition to the above packets which explicitly start with a protocol
*verb*, *reply packets* can merely consist of a text representation of a
directory listing or an entry within a directory listing.

A DIR_ENTRY is a tab delimited line of text consisting of three fields:

- the **size** of a file, blank for directories
- the **timestamp** of a file or directory
- the **name** of the file, or the name of the directory terminated with '/'

A DIR_LIST is multiple lines of DIR_ENTRY text, where the
first line is the containing directory, and subsequent lines
are entries within it.

	     \t 2023-09-01 06:00:00 \t /fully/quallifed/folder/
	1023 \t	2023-09-12 08:12:59 \t someFile.txt
	     \t	2023-09-12 08:15:59 \t someSubDirectory/
	1023 \t	2023-09-12 08:22:59 \t someOtherFile.txt

RENAME is the only request type to return a DIR_ENTRY.
Otherwise, the following requests return DIR_LISTS
of the given dir upon success:

- LIST			dir
- MKDIR			dir name
- DELETE		dir (single_filename | entry_list]

In this document the words *DIR_LIST* and *DIR_ENTRY* are
used to describe these types of reply packets, but those words
themselves are NOT part of the protocol.



### Session Connection

A Session is initiated by a client after successfully
connecting to a remote *socket* and sending HELLO.
The Server replies with WASSUP to indicate it is ready
to start receiving command packets:

- CLIENT --> HELLO
- SERVER <-- HELLO
- SERVER --> WASSUP
- CLIENT <-- WASSUP

Either the client or the server consider the Session to be
irretrievably 'lost' (dead) if a call to *sendPacket()* fails (which
apparently never happens), or a call to **getPacket()** *times out* or
receives a *null (empty) reply* (which is the typical failure mode).
In either case the method invalidates the Session (by setting the
*SOCK* member of the Session to NULL) which then ceases to call
sendPacket() or getPacket().

An invalid Session is also referred to as a a *lost socket* in
this discussion.

A Server invariantly exits the thread associated with the lost
socket, but it is upto the Client to decide what to
do if it detects a lost socket. The FC::Window currently
closes itself on a lost socket, and, if it is the last window,
currently closes the fileClient application.

This is opposed to an explicit user Disconnect command in the
current implementation of the remote FC::Pane, in which case
the FC::Window remains open, with the remote pane disabled and a
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

- Sent by clients, like the FC::Pane, when they are done with a connection
- Sent by servers, like the SerialBridge in buddy, when the server is shutting down

*Following is a description of the current implementation.*

For example, when the user closes a FC::Window, the window sends an EXIT
message to buddy's SerialBridge with a slight delay before closing it's own socket.
The delay allows the packet to be sent before the socket is closed. The received EXIT
allows the SerialBridge Server to free up the thread and any memory associated with
the connection.

Or vice-versa, when buddy shuts down the SerialBridge, as each thread terminates,
it sends an EXIT message to the associated FC::Window (again with a small
delay before it closes the socket), and the FC::Window knows to close itself.

In either case the recipient of the EXIT message knows not to send another
EXIT message back to the sender of the first EXIT message.


### Asynchronous Messages

- ENABLE - msg
- DISABLE - msg

Asynchronous messages can be sent from a Server to the connected client
at any time, including while in the middle of executing a command.
These are currently sent from buddy to all connected FC::Windows
when the COM_PORT goes offline or comes online, ie:

	DISABLE - Arduino Build Started
	DISABLE - Connection to COM3 lost
	ENABLE  - COM3 Connected

Note that ENABLE and DISABLE use " - " (space dash space) as the
delimiter between the verb and the message parameter.


### ERROR

Any command can terminate in an ERROR message.

Regardless of the configuration, ERROR messages are ultimately
sent to the FC::Pane that is executing the command,
and reported to the user in a dialog box.

Note that ERROR uses " - " (space dash space) as the
delimiter between the verb and the message parameter.



### Synchronous Commands

- LIST			dir
- MKDIR			dir name
- RENAME		dir name1 name2
- DELETE		single_filename

These commands are passed as a single line packet, and
considered to be executed in a single operation, with a
DIR_LIST or DIR_ENTRY being returned upon success.

All of the above return a DIR_LIST upon success except
RENAME which returns a DIR_ENTRY (as the fileClient is
optimized to update the UI only for the changed filename
in that case).

There are no PROGRESS messages returned by these
commands and they cannot be ABORTED once issued.

Note that the Client Session::doCommand() handles local
synchronous commands and so they never make it into protocol
packets.


# Asynchronous Commands

The XFER and 'DELETE entry_list' commands can take
a long time, can retun intermediate PROGRESS messages,
and can be ABORTED.

Upon final success they return a DIR_LIST.

PROGRESS messages are sent from the Server to the Client to
give the client information needed to update a progress dialog.

	PROGRESS ADD	num_dirs num_files  // adds dirs and files to progress range
	PROGRESS DONE   is_dir              // increments num_done for dirs and files
	PROGRESS ENTRY  entry               // displays the path or filename. hides the 2nd gauge if shown
	PROGRESS SIZE   size/               // start showing the 2nd 'bytes transferred' gauge
	PROGRESS BYTES  bytes               // set the value for the 2nd bytes transferred gauge

ABORT can be sent by the Client to stop an asyncrhonous command,
which case the Server returns ABORTED to acknowledge the cessation
has taken place.


### FC::Pane

*Implementation Details*

Commands from the Client are handled by Session::doCommand().

Local commands are handled directly by the Session, with
asynchronous ones directly updates the $progress window along the
way, while checking for $progress->aborted(). Internally local
commands return an FILE_INFO_LIST (which is like a DIR_LIST
but is a FS::FileInfo object for which "is_dir=1", with
the {entries} member populated.

Remote commands are impplmented in the FC::Pane to make use
of the pane's doCommandThreaded() function, which starts by sending
the command to the Server, and then monitoring the return for
PROGRESS and ABORT messages until it finally receive a terminating
DIR_LIST or ERROR message.

Care was taken in the FC::Pane to ensure the atomic nature of
commands, by making sure that while a threaded command is in
progress, no other UI can be accessed that might initiate
another command.  This is done by FC::Pane setting a
FC::Window->{thread} member as a semaphore while a threaded
command is in progress.

### FC::Pane doCommandThreaded()

FC::Pane.pm uses *Perl threads and WX::Events* to
  implement the non-blocking doCommandThreaded() method

See: https://metacpan.org/dist/Wx/view/lib/Wx/Thread.pod

- for remote commands, the FC::Pane creates a
  *Perl thread* for doCommandThreaded() which calls
  the regular Session::doCommand(), thus preventing the
  system from blocking on a paricular getPacket() call.
- when doing so, doCommandThreaded() sets FC::Window->{thread}
  as a semaphore to prevent the window or panes from re-entering
  a subsequent command, double clicking, sorting, or
  basically doing anything in either pane, while not
  explicitly disabling it.
- the regular Session::doCommand() sends the multi-line
  command through the socket to the associated Server/Session.
- SerialSession::doSerialRequest *blocks* until the serial port
  is available to send a new requests, so that only one
  serial_file_request at a time is sent to the teensy serial port.


### teensyExpression

teensyExpression C++ uses *teensyThreads* to handle multiple
  simultaneous serial_file_requests.

- theSystem.cpp new's a buffer for each serial request as
  it comes in, and when ready (\n is received) starts a
  a *thread* to call fileSystem.cpp handleFileCommand().
- the thread sends one or more *file_replies* to the
  serial port for PROGRESS' and terminating with
  a DIR_LIST, ABORTED, or ERROR file_reply

PRH: Note that there is currently nothing to stop intermingling
of file_replies generated by fileSystem.cpp.  It needs
a **semaphore** which can just be a memory variable to
prevent such intermingling.


### Aborting doCommandThreaded()

Aborting a remote_request started by doCommandThreaded() is
complicated enough that it warrants a more detailed description.

*Using DELETE remote as an example*

The key is that SerialSession::doSerialRequest is tied to a particular
FC::Pane/Window by the thread doSerialRequest() is running
in (as there is only one thread/socket per FC::Pane).

- FC::Pane::onIdle() checks if a threaded command
  ($this->{parent}->{thread}) is being aborted ($this->{progress}
  && $this->{progress_aborted}) and if so, sends one ABORT packet
  to the SerialSession (using the $override_protocol parameter
  to sendPacket).
- SerialSession::doSerialRequest(), which is looping waiting for
  file_replies from the teensy for the initial DELETE file_request,
  calls getPacket(0), without blocking, to see if any ABORT packet
  has arrived. Remember that sessionThread is no longer blocking on
  a call to getPacket so doSerialRequest)( can call getPacket(0)
  without any problem.
- If SerialSession::doSerialRequest() receives an ABORT packet,
  it will issue a SECOND file_request with the SAME REQUEST
  NUMBER for the ABORT.
- teensyExpression theSystem.cpp will receive the 2nd file_request
  and start another threaded handleFileCommand.
- the second handleFileCommand(ABORT) will call addPendingAbort(req_num)
  to add the request number to an array of pending_aborts, and return.
- the original handleFileCommand(DELETE) will call abortPending(req_num)
  during it's processing loop.  If abortPending(req_num) finds a pending
  abort, it will both send a serial ABORTED numbered file_reply, and
  return true to tell handleFileCommand() to cease processing the DELETE
  command and return.
- The ABORTED message is passed back up the chain until it is
  returned by a WX $THREAD_EVENT to onThreadEvent() in the UI thread,
  which then shows the COMMAND ABORTED dialog, after which it closes
  the $progress window and call setContents() and populate() repopulate
  the pane since it's contents are now indeterminate.


# XFER Protocol and Implementation
