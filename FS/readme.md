FS PROTOCOL

## Protocol

### All Packets

- HELLO
- WASSUP
- EXIT
- ENABLED		- msg
- DISABLED		- msg
- ERROR			- msg
- LIST			dir
- MKDIR			dir name
- RENAME		dir name1 name2
- ABORT
- PROGRESS		ADD 	num_dirs num_files
- PROGRESS		DONE 	is_dir
- PROGRESS		ENTRY 	entry
- DELETE		dir (single_filename | entry_list]
- XFER			is_local dir target_dir [name | entry_list]
- GET           dir filename
- PUT			dir filename
- BASE64		offset bytes checksum contents
- CONTINUE

### Connection

- CLIENT --> HELLO
- SERVER <-- HELLO
- SERVER --> WASSUP
- CLIENT <-- WASSUP

### EXIT

- Sent by fileClientPanes when they close to free Server Threads
- Sent by ServerThreads when the Server (buddy) is shutting down

### Asynchronous Messages

- ENABLE  msg
- DISABLE msg

These are sent from buddy to the fileClientPane when the COM_PORT
goes offline or comes online, ie:

	DISABLE - Arduino Build Started
	DISABLE - Connection to COM3 lost
	ENABLE  - COM3 Connected

### ERROR

Almost any operation can report an ERROR which ceases
the operation.

### Synchronous Commands

- LIST			dir
- MKDIR			dir name
- RENAME		dir name1 name2
- DELETE		single_filename

These commands take place in a single atomic operation
with a DIR_LIST or DIR_ENTRY or FILE_ENTRY being returned.



## Command Sessions

Certain commands are asynchronous in naature and have a delimited lifetime.
The simplest one, DELETE is finished when the client receives a DIR_LIST

PROGRESS gives the client informatio to update a progress dialog.

	PROGRESS ADD	num_dirs num_files 	// adds dirs and files to progress range
	PROGRESS DONE   is_dir				// incrementes num_done for dirs and files
	PROGRESS ENTRY  entry				// displays the path ro filename

ABORT is sent by the client to stop an operation, as well as
returned by an operation to acknowledget the cessation.


### DELETE dir entries

Client waits for a DIR_LIST indicating the operation is complete,
while looking for ABORT and processing PROGRESS messages.

Server sends PROGRESS messages as it recurses new directories
and counts their entries, and per each item deleted.



## Threading, Processes, and Sockets / Serial connections

### fileClient is single threaded

The fileClient (all my WX Apps) is a single thread program
running in a single process. Yet, due to magic inside of WX,
it is possible for it to have multiple connections (sockets)
open to the Remote seerver at any time.

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
