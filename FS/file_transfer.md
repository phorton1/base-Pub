# File Transfers

This document is extemporaneous in nature and will require
updating previous documents when File Transfers are implemented.

**File Transfers are always initiated by the FC::Pane which is the only
object that (indirectly) knows the two Sessions involved.**

**A Session currently only knows how to deal with one fileSystem at a time.**

### Requirements

- local to local transfers should take place in the fileClient process
  with a minimum of buffer encoding .. I think passing BASE64 packets
  would be *ok*.
- in all cases, directory traversals will take place on the machine that
  has direct access to the given file_system
- socket communications should be minimized possible, i.e., for the special
  case of the ThreadedSession talking to the SerialSession.

The SerialBridge, if active, will do the local directory traversal,
  file and directory creation, reading and writing of files, buffering
  and de-buffering BASE64 serialized file_commands and file_replies,
  and shall only send PROGRESS messages over the socket to the
  pane's ThreadedSession until it passes the final ERROR, ABORTED,
  or DIR_LIST packet for the entire operation.

All this logic will be implemented in the base Session to allow for
local-local transfers.  It is not clear how this fits, if at all
into the exising doCommand() hierarchy.

## Stab at Design

	Session::doCommand(
		PUT,
		$dir,
		$entries_or_file_name,
		$target_dir,
		$progress,
		$caller,
		$other_session )

Conceptually, the PUT command seems to orchestrate a transfer
from THIS session to the OTHER session.

But let's notice how this compares to the current doCommand()
implementations, starting with the most complicated case.

### Complicated case

- this_session == FC::ThreadedSession connected to SerialSession
- other_session == local FS::Session

this_session is a ThreadedSession connected by socket to
a SerialSession running on the same machine, which is,
in turn, connected to teensy 'SerialServer' over the COM port.
As it currently exits:

- the ThreadedSession will call ClientSession::doCommand()
- doCommand() will call the _put() method
- the _put() method will send the command as a packet
  to the SerialSession.
- the _put() method will loop, similar to the current
  _delete method, handling PROGRESS messages, until it
  get a final ERROR, ABORTED, or fileInfo packet.
- PROGRESS messages will be handled by ThreadedSession onThreadEvent() calls
- _put() will return the final packet to doThreadedCommand() which will
  result in onThreadEvent() reporting any terminal ABORT or ERROR messages,
  closing the $progress dialog if any, and repopulating
  DESTINATION (other) pane.
- until then, the (threaded command) Pane::onIdle() method
  will check for any $progress->aborted() states and send
  them as an ABORT packet to the SerialSession.

- SerialSession will receive the PUT command packet and
  forward it as a serialized file_command to the teensy.
- While it is forwarding PROGRESS serialized file_replies
  back over the socket to the ThreadedSession _put() method,
  it will also listen for out of band ABORT packets from
  the ThreadedSession, which it will then forward as same
  serial_number file_commands to the teensy.
- When it receives a final terminal serialized file_reply,
  it will, after sending it by socket to the ThreadedSession,
  exit it's doSerialMethod() and return control to the
  BridgeServer (FS::Server).


The teensy fileCommand(req_num) will orchestrate
a PUT back to the SerialSession doSerialRequest() method
which will need to be made smarter.  The teensy will


- traverse directories as needed to implement multiple item requests.
- it is assumed that only empty directories would be sent as mkdirs,
  but that a machine can make any needed subdirectories upto a given
  file (so that we don't make every directory as a separate packet,
  but only when absolutely necessary)
- PROGRESS messages are not needed for file transfers, except maybe
  to ADD dirs and files.
- The source file Session shall decide what progress messages to
  send.
- MKDIR_EMPTY, FILE, and BASE64 packets contain most of the needed
  progress information.

**==> means serial comms, --> means socket comms.**


### ThreadedSession --> PUT_LOCAL /songs test.song /junk/data/songs

With PUT_LOCAL the ThreadedSession tells the SerialSession that it should
intercept the destintation of this put as being the local file system.
The SerialSesccion strips the _LOCAL off, and forwards the rest to
the teensy as a serialized file_command, which then in turn calls
fileCommand(req_num) which is arbitrarily 12 in the following example.
What follows is a condensed example, where lengths, request numbers and
file_command and file_reply fields of serial requests are not shown.

	doSerialRequest(12) ==> PUT /songs test.song /junk/data/songs
	fileCommand(12) 	<== PUT /songs test.song /junk/data/songs
	fileCommand(12)		==> FILE size ts /junk/data/songs/test.song
	doSerialRequest(12)	<== FILE size ts /junk/data/songs/test.song

Upon receiving the PUT command, fileCommand() starts the conversation
with a FILE file_reply.  doSerialRequest(FILE) knows that the destination
is the local file system, and it is in a PUT command, so it performs the
file receiving protocol. It is also monitoring for ABORT packets from
the ThreadedSession.

- it checks if there is room for the file and 'returns' (sends)
  a serialized ERROR file_command if it wont fit.
- it opens /junk/data/songs/test.song for output
  and sends a serialized if can't fit.
- sends a PROGRESS path size packet to the ThreadedSession
- sends a CONTINUE serialized file_command to the teensy

	doSerialRequest(12)	--> PROGRESS /junk/data/songs/test.song size
	ThreadedSession     <-- PROGRESS /junk/data/songs/test.song size
	doSerialRequest(12)	==> CONTINUE | OK | ERROR | ABORT
	fileCommand(12)		<== CONTINUE | OK | ERROR | ABORT

The terminal OK is sent by doSerialRequest(PUT) when the file is finished.
If the size was zero, then it's finished after the initial FILE message.
Until there is a terminal messages, fileCommand() will continue orchestrating
the session. Normally doSerialRequest() will send CONTINUE after the initial
FILE message, and fileCommand() will send one or more BASE64 messages.

	fileCommand(12)		==> BASE64 offset size ENCODED_CONTENT
	doSerialRequeat(12) <== BASE64 offset size ENCODED_CONTENT
	doSerialRequest(12)	--> PROGRESS BYTES offset
	ThreadedSession     <-- PROGRESS BYTES offset
	doSerialRequeat(12) ==> CONTINUE | OK | ERROR | ABORT
	fileCommand(12)     <== CONTINUE | OK | ERROR | ABORT

doSerialRequest(12) decodes the ENCODED content, verifies the checksum,
write the bytes to the file, sends a progress message to the
ThreadedSession, and 'replies' (sends a serialized file_command)
to fileCommand(12).

Eventually fileCommand(12) itself finishes, encounters an error,
or recieves an ERROR or ABORT message from doSerialRequest() and the
PUT unwinds.

	fileCommand(12)		==> OK | ERROR | ABORTED
	doSerialRequest(12)	<== OK | ERROR | ABORTED
	doSerialRequest(12) --> DIR_INFO | ERROR | ABORTED
	ThreadedSession     <-- DIR_INFO | ERROR | ABORTED

If OK, doSerialRequest() has already closed the file when it sent
it's own OK, and since it knows the destination is the local file
system, it knows the target_dir that the other pane needs.
So doSerialRequest(PUT_LOCAL) somewhat weirdly returns a local
for the OTHER pane DIR_INFO as the final result. That gets
returned by ThreadedSession::ClientSession::_put() to doCommandThreaded()
which then passes it as the terminal event to onThreadEvent(),
which then knows to call $other_pane->setContent(DIR_INFO)
and $other_pane->populate() to update the OTHER pane.

Otherwise, PUT generally cannot return a FileInfo for the final
destination so, in those cases it merely returns OK.

The whole question of how fileCommand() is going to have an out-of-band
same serial number conversation has not been addressed. Just assume
that a subsequent doSerialRequest(12) somehow works and that
fileCommand() knows how to gracefully wait for, and time out,
on the protocol.

### local FS::Sesion PUT --> another local FS::Session

Well, THIS session knows it is local.
Perhaps it knows the other is local and does the same
PUT_LOCAL thing as before.

There is no Socket, so the use of arrows is a bit weird.

	Session::doCommand(
		PUT,
		/junk/data,
		test.rig,
		/junk/data/backups
		$progress,
		'doCommandSelected',
		$other_session )


Session::doCommand() reports any errors and returns blank or OK or a DIR_INFO
It is assumed that any errors are reported and _put() and doCommand(PUT) return blank
on any errors.  On the other hand doCommand(FILE) shall return errors which are reported
by the caller.

- this_session::_put() opens /junk/data/test.rig for reading
- this_session::_put() calls other_session::_file() directly
- other_session::_file(/junk/data/backups, test.rig, ts, size, $progress)
  - checks if there's room and opens the /junk/data/backups/test.rig for writing
  - calls $progress->addEntry(/junk/data/backups/test.rig,size)
  - returns CONTINUE | OK | ERROR | ABORTED
- this_session::_put(CONTINUE) reads and encodes bytes from the file
  and calls other_session::_base64(offset,bytes,content,$progress)
- other_session::_base64()
  - decodes the content and verifies the checksum
  - writes the decoded content to the file
  - calls $progress->bytes(bytes)
  - returns CONTINUE | OK | ERROR | ABORTED

This continues until this_session() gets a terminal node
at which case it shows the ABORTED message if any, or
as with the previous example, it knows to return a
DIR_INFO for the other pane, which doCommandSelected()
knows to use to call $other_pane->setContent(DIR_INFO)
and $other_pane->populate().

Any errors were already reported.

## Generalizations

The correct verb is PUT not XFER
There is an additional FILE verb.
doCommand() probably needs another parameter.
There are base Session _put(), _file(), and _base64() methods/commands.

This notion of a Session knowing whether the other pane is local
is important.  I used PUT_LOCAL to enapsulate it, but I think it
is another parameter (OTHER_IS_LOCAL) in packets, and should
be 'gettable' from the base FS::Session $session->{IS_LOCAL}==1

Thus at the end, a PUT could AWAYS return the other pane directory
calling $other_session->doCommand(LIST) if it needed to cuz it
only got an OK from the remote.
