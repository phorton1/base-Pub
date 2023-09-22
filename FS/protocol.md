# Pub::FS

## Protocol General

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


## Command Sessions

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


### DELETE dir entries

Client waits for a DIR_LIST indicating the operation is complete,
while looking for ABORT and processing PROGRESS messages.

Server sends PROGRESS messages as it recurses new directories
and counts their entries, and per each item deleted.


# THE REST OF THIS README IS INVALID

**I have implemented *teensyThreaded* fileCommands in the
teensyExpression C++ code and *Perl threads + WX::Events*
in the doCommandThreaded() methods for remote requests by
the fileClientPane!!**



## Threading, Processes, and Sockets / Serial connections

### fileClient is single threaded

The fileClient (all my WX Apps) is a single thread program
running in a single process. Yet, due to magic inside of WX,
it is possible for it to have multiple connections (sockets)
open to the Remote server at any time.

A single fileClientWindow will be in onIdle(), checking
for "broadcast" async ENABLE/DISABLE and EXIT messages.

It is possible for multiple different fileClientPanes
to attempt to initiate synchronous sessions with the
RemoteServer (i.e. one pane issues LIST while another
pane is in the middle of a DELETE or XFER Command Session.

This would be ok if the fileClientWindows ran in separate
threads, but they don't. If an attempt to initiate a
second Command Session were to proceed, the system gets
messed up because the second session getPacket(1) would
essentially BLOCK the first session from continuing to
get packets (since there is only one thread, only one
of the two windows can actually be active at a time).

Therefore we prevent the initiation of a second Command Session
by using a global non-shared variable $in_protocol, in Session.pm,
and the second session's attempt to initiate the Command Session
fails because sendPacket() will fail if $in_protocol, and
thus the Second Session terminates it's (WX event) command
immediately with a failure,.

Session.pm works ok in actual multi-threaded apps (i.e.
the RemoteServer) because, in effect, the $in_protocol
variable is thread specific, copied to each subsequent
thread, so the effect is that, in a true multi-thread
environment a THREAD may only have one Command Session
active at a time, which seems reasonable.



### teensyExpression fileSystem.cpp is single thread

Although it currently runs from the timerLoop(), which is
a separate 'thread' from the main UI loop, the current implementation
of the fileSystem.cpp 'server' in the teensy is single threaded.


### SessionRemote is multi-threaded but only has one COM port

The RemoteServer is multi-threaded and can handle multiple
simultaneous connections, creating thread specific SessionRemote
objects for each connection.  However, since there is only one COM port
(and in addition the teensyExpression can only handle one request
at a time), the SessionRemote BLOCKS doRemoteRequest requests until
the current request is finished thru the use of a shared
$in_remote_request variable.



## WX Threads

WX apps can apparently be multi-threaded, but only the main
thread can interact with the UI.

From: https://metacpan.org/dist/Wx/view/lib/Wx/Thread.pod

*It's necessary for use Wx to happen after use threads::shared.*

A thread can be started globally with the typical threads
create method.  Such a global thread would need access
to a global WX::EvtHandler (i.e. a Frame or Window)
to communicate events to it:

	my $DONE_EVENT:shared = Wx::NewEventType;
	my $frame = Wx::Frame->new( ... );
	EVT_COMMAND( $frame, -1, $DONE_EVENT, \&done );

	my $worker = threads->create( \&work );

	# Communicate with the UI thread via PostEvent

	sub work
	{
		# There is no while(1) or any looping in the example,
		# it would seem that the would exit immediately.
		# I added a control loop.

		while (1)	# my addition
		{
			# do stuff here ...

			# the example does not show the declaration of $result
			# the following apparently create $result value:shared

			my $threvent = new Wx::PlThreadEvent( -1, $DONE_EVENT, $result );
			Wx::PostEvent( $frame, $threvent );
		}
	}

	sub done
	{
		my( $frame, $event ) = @_;
		print $event->GetData;
	}



### Creating threads from WX Events (i.e from the window)

*All event handlers that directly or indirectly cause a thread creation must clean
@_ before starting the thread.*

	sub OnCreateThread
	{
		my( $self, $event ) = @_;
		@_ = ();
		threads->create( ... );
	}


### Sending events to worker threads

	sub work
	{
		while (1)	# my addition
		{
			# do stuff here ...

			my $progress = new Wx::PlThreadEvent( -1, $DONE_EVENT, $progress );
			Wx::PostEvent( $frame, $progress );

		    # do more stuff ... send second event indicating completion

			my $end = new Wx::PlThreadEvent( -1, $DONE_EVENT, $result );
			Wx::PostEvent( $frame, $end );
		}
	}


## Thought Experiment

So, can using threads in Wx provide any benefits, or relief, to
handling multiple simultaneous comand session (assuming we somehow
handle them in the teensyExpression::fileSystem.cpp server)?

I don't think that I can assume that the teensy SDFat library is thread safe
but apparently it sort of is, inasmuch as the teensy 'threads' implementation
is process switching.  I can only imagine deleting a file in one 'thread'
while another 'thread' is writing to it.

I have a working example of a worker thread in fileClientWindow.pm,
To get it to work, I added use threads and use threads:shared to
all WX and FS files.


### First issue

The fileClientWindow's {session} member is NOT a shared variable.

So, for instance, as currently implemented, the fileClientPane could
do something that loses $session->{SOCK} and the worker_thread would
have no way of knowing about it.

I'm still struggling to see how this could be useful.

Maybe i would create a thread and new session to handle
"Command Sessions", which would have their own socket
to the remoteServer ... logging in and everything ...
to do the Asynch command.  The thread would exit
upon completion (and do I have to 'join' it or something?,
or not use detach).

Then I try to change teensyExpression and fileSystem.cpp
to somehow be multi threaded (using Teensy threads),
where a 'teensy thread' is created for each fileSystem
command (Command Session).

I could experiment with that separatelly.



On a server, we fork off a new thread for each session, but
in the WX app, the session is associated with the window,
and is expected to be persistent for handling of EXIT
and ENABLE/DISABLE notifications.

None of this is helping me with my next task, which is to
implement the protocol for XFER which will, in my current
plan, take place entirely within the Remote Session/Server,
with only PROGRESS and final DIR_LIST (or ERROR) results
back to the WX app.



## Threaded teensyExpression2 fileSystem::handleFileCommand()

- file_command: would be sent from buddy/SessionRemote to the teensy
  with an always inrementing instance number
- file_reply: and file_reply_end: would be sent back to buddy/SessionRemote
  with the instance number, possibly interlaced from multiple threads.
- all file_reply: and file_reply_end lines would need to be sent
  in their entirety, in one fell swoop as it were, implying a need
  for some kind of protection on the fileSystem's new "sendPacket"
  method.


## Continuing ...

OK, so I think I have created a threaded fileSystem handleFileCommand,
for the moment ignoring the possibility of mulltiple teensy threads
sending part of a line to the fsd at the same time.

buddy is now built to handle multiple simultaneous remoteRequests,
each of which gets their own request num:

	file_reply(XX):  blah
	file_reply_end(XX)

	while (!$file_reply_ready{$req_num})  # etc

So now onto the thorny issue of synchronous, versus asynchornous,
Session::doCommand() in the fileClientPane (and fileClientWindow) ...

Once again, I can't just spawn a thread per command because
$session->{SOCK} is not shareable and it's a single threaded
app ... and $session is not a shared variable.

If SOCK gets invalidated in a thread, there's no way to report
it back to the main process (assuming that the thread works
the same in WX as normally, the $session will be copied into
the new Perl interpreter, but not back)

And the whole Session::doCommand structure is built on the
idea that getPacket is session specific ... ok, so a given
fileClientWindow/Pane can only be in one doCommand at a time.

We *can* have a shared variable, that might be a hash
indexed by the windows 'instance_num', that can report
the success, or failure of a threaded call to Session::doCommand,
inasmuch as the RESULTS of the commands ARE shareable.

So,

- ignore async EXIT/ENABLE/DISABLE messages in fileClientWindow::onIdle
  by disconnecting it for the continuing experiment.

- introduce %doCommandResult{instance}::shared for passing the


- have a generical fileClientPane::onThreadMsg() method
  that receives results from the doCommandThread and
  'finishes' the operation as appropriate.




## INITIAL THREADED IMPLEMENTATION

Everybody is threaded.

Still have to fix fileClientWindow onIdle().

I have concerns about now needing to use the heap for each fileCommand,
but here's how it works;

- there is now a fileClientPane::doCommand() instead of calling $this->{session}->doCommand()
- fileClientPane::doCommand() still calls $this->{session}->doCommand() for $local operations.
- this doCommand() takes an additional 'caller' parameter so we'll know what to do with results
- for remote operations fileClientPane::doCommand()
	- starts a doCommandThreaded() thread for the remote
	- returns -2 to indicate the caller should bail and we'll take care of it later.
- doCommandThreaded() calls %this->{session}->doCommand() but without the $progress param
- fileClientPane implements addDirsAndFiles(), addDone(), and addEntry() to look like a progress dialog
- there is now an doClientPane::$THREAD_EVENT event taype
- fileClientPane registers EVT_COMMAND($this, -1, $THREAD_EVENT, \&onThreadEvent );
- fileClientPane::onThreadEvent() handles communications from doCommandThreaded()


When the Session::doCommand() is finished, or on any calls to addDirsAndFiles(), addDone(),
or addEntry() occur, a new Wx::PlThreadEvent( -1, $THREAD_EVENT, $rslt ) is posted to
the the WX event dispatcher.

For PROGRESS messages, $rslt is the recombined Text from typical progress parameters,
which is then re-split by tabs and passed to the real $this->{progress} dialog,
if it exists, in onThreadEvent().

For 'terminating' messages, if they are the proper ref(FS::Pub::FileInfo)
onThreadEvent() 'finishes' the command that was left dangling by the -2 return earlier,
based on the 'caller'

- setContents - does a setContent($rslt) and populate()
- doMakeDir - does a setContent(undef) and populate, although this should be changed
  to make sure the doCommand(MKDIR) returns the DIR_LIST and then call
  setContents($rslt)
- doCommandSelected - destroys $this->{progress} if it exists, and calls
  setContent($rslt) and populate()

If the doMakeDir issue was cleaned up, then all would just do setContent($rslt)
and populate(), but doCommandSelected would first destroy the progress dialog.

I also need to double check what happens to make setContents() write out the
red 'Could not get directory listing message: on failures (-1).

Then there is the somewhat huge issue of doing the XFER protocol, which
will also need large buffers on the heap.

And the inevitable problem of a threaded session setting SOCK to null






--------------------------------------------------------------
