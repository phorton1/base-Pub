# Protocol

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
- WASSUP		is_win(0/1) SERVER_ID
- EXIT
- ENABLED 		- msg
- DISABLED 		- msg
- ERROR			- msg
- LIST			dir
- MKDIR			path ts  \[ may_exist ]
- RENAME		dir name1 name2
- ABORT
- ABORTED
- PROGRESS		ADD 	num_dirs num_files
- PROGRESS		DONE 	is_dir
- PROGRESS		ENTRY 	entry  \[size]
- PROGRESS      BYTES   bytes
- DELETE		dir \[single_filename | (ENTRY_LIST)]

- PUT			dir target_dir \[single_filename | (ENTRY_LIST)]
- FILE          size ts fully_qualified_target_filename
- BASE64		offset bytes ENCODED_CONTENT
- BASE64 		0 0 ERROR - message
- CONTINUE
- OK


The delimiter for fields in packet lines
is a tab "\t", with the exception of the single line ERROR packet
which uses "space dash space" as the delimter.

The *dir* and *target_dir* parameters in the above packets
are always **fully qualified paths** and the other parameters
(name, name1, name2, and the *entry_list* items) are *leaf names*
within the fully qualified dir path.

Packets that use *ENTRY_LIST* are muliple lines with the first
line containing the command and listed parameters, always including a
fully qualified *dir* parameter, with subsequent lines containing
a series of DIR_ENTRIES.


### ENTRY_LIST, DIR_LIST, DIR_ENTRY, and FILE_ENTRY

In addition to the above packets which explicitly start with a protocol
*verb*, some *command packets*, and most final *reply packets* consist
of a text representation of all or part of a directory listing.

A DIR_ENTRY is a tab delimited line of text consisting of three fields:

- the **size** of a file, blank for directories
- the **timestamp** of a file or directory
- the **name** of the file, or the name of the directory terminated with '/'

If the name is not terminated with '/', the DIR_ENTRY is also to be
considered to be a FILE_ENTRY.

An ENTRY_LIST is a series of lines containing DIR_ENTRIES
that are relative to the fully qualified dir given in the command.

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
- MKDIR			path ts
- DELETE		dir (single_filename | entry_list]



### Session Connection

A Session is initiated by a client after successfully
connecting to a remote *socket* and sending HELLO.
The Server replies with WASSUP and it's ID to
indicate it is ready to start receiving command
packets:

- CLIENT --> HELLO
- SERVER <-- HELLO
- SERVER --> WASSUP SERVER_ID
- CLIENT <-- WASSUP SERVER_ID

The syntax of a SERVER_ID will be explained later.

Either the client or the server consider the Session to be
irretrievably 'lost' (dead) if a call to call to **getPacket()**
*times out* or receives a *null (empty) reply*,
In either case getPacket() invalidates the Session (by setting the
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


### EXIT

- Sent by clients, like the FC::Pane, when they are done with a connection
- Sent by servers, like the SerialBridge in buddy, when the server is shutting down

*Following is a description of the current implementation.*

For example, when the user closes a FC::Window, the Window sends an EXIT
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


### Terminal Packets - ERROR, ABORTED, OK

Any command can terminate in an ERROR message.
Regardless of the configuration, ERROR messages are ultimately
shown to the user in a dialog box.
Note that ERROR uses " - " (space dash space) as the
delimiter between the verb and the message parameter.

Session-like commands can terminate with ABORTED
message if the command is ABORTED by the user.

The PUT command can additionally terminate with OK,
indicating that the PUT 'session' has completed
successfully.

There is a special case of a failure during a PUT
command if the host cannot read from the file while
generating a BASE64 packet where it returns an
ERROR within the BASE64 packet.

	BASE64 0 0 ERROR - msg


### Simple Commands

- LIST			dir
- MKDIR			path ts \[may_exist]
- RENAME		dir name1 name2
- DELETE		dir single_filename

These commands are passed as a single line packet, and
considered to be executed in a single operation, with a
DIR_LIST or DIR_ENTRY being returned upon success.

All of the above return a DIR_LIST upon success except
RENAME which returns a DIR_ENTRY (as the fileClient is
optimized to update the UI only for the changed filename
in that case), and MKDIR may_exist, which is used in the
FILE protocol to create empty directories, and returns
OK or an error if the existing thing is not a directory,
or the typical error if a directory could not be made.

There are no PROGRESS messages returned by these
commands and they cannot be ABORTED once issued.

Note that the base Session::doCommand() handles local
synchronous commands and so they never make it into protocol
packets.


### Session-like Commands

The PUT and "DELETE dir ENTRY_LIST" commands are session-like
in nature can take a long time, can retun intermediate PROGRESS
messages, and can be ABORTED.

Upon final success DELETE returns a DIR_LIST.
Upon final success PUT returns an OK.

*note that we are talking about the PROTOCOL. In the
implementation of doCommand() PUT can return a DIR_LIST
for the 'other' pane upon success, depending on the
context of the doCommand() call.*

PROGRESS messages are sent from the Server to the Client to
give the client information needed to update a progress dialog.

```
	PROGRESS ADD	num_dirs num_files  // adds dirs and files to progress range
	PROGRESS DONE   is_dir              // increments num_done for dirs and files
	PROGRESS ENTRY  entry  [size]       // displays the path or filename. sets the range if \[size] or hides guage if not
	PROGRESS BYTES  bytes               // set the value for the 2nd bytes transferred gauge
```

ABORT can be sent by the Client to stop an session-like command,
which case the Server returns ABORTED to acknowledge the cessation
has taken place.



### PUT Protocol

PUT commands are sent to the HOST device which has local access to the
file system containing the files for the PUT command. It then
sends FILE and BASE64 commands to the CLIENT device which is receiving
the file and which writes it out to its file system.

```
	CLIENT 	--> PUT dir target_dir [single_filename | (ENTRY_LIST)]
	HOST 	<-- PUT dir target_dir [single_filename | (ENTRY_LIST)]
```

The HOST recurses it's local file system as necessary to send
one or more FILE messages back to the CLIENT, and for each
FILE message, zero or more BASE64 messages.  For 0 sized
files there is an understanding that no BASE64 packets will
be sent for that particular file and the CLIENT will immediately
reply with OK.

```
	HOST 	--> FILE size ts fully_qualified_target_filename
	CLIENT  <-- FILE size ts fully_qualified_target_filename
	CLIENT  --> CONTINUE | OK | ERROR | ABORTED
	HOST 	<-- CONTINUE | OK | ERROR | ABORTED
```

While the HOST receives appropriate CONTINUE messages, it will
continue to send BASE64 messages

```
	HOST	--> BASE64 offset bytes ENCODED_CONTENT
	CLIENT  <-- BASE64 offset bytes ENCODED_CONTENT
	CLIENT  --> CONTINUE | OK | ERROR | ABORTED
	HOST 	<-- CONTINUE | OK | ERROR | ABORTED
```

When the HOST has finished successfully sending all of the
files, it will reply with its own OK message signalling
that the PUT session is finished.

```
	HOST 	--> OK
	CLIENT	<-- OK
```

#### Unsuccesful termination of a PUT session

PUT sessions can terminate for a number of different reasons.
There is a general agreement between the HOST and the CLIENT
that a session that a FILE in progress that is terminated
will also terminate the PUT session, however, in all cases
the PUT session itself is terminated with a final message
back to the client.  Here are some examples.

PUT session terminated because client could not open the output file:

```
	...
	HOST 	--> FILE size ts fully_qualified_target_filename
	CLIENT  <-- FILE size ts fully_qualified_target_filename
		// at this point the client gets an error opening the file
		// and effectively ends its PUT session
	CLIENT  --> ERROR - could not open file for output
	HOST 	<-- ERROR - could not open file for output
		// host stops sending any more FILE or BASE64 messages.
		// and ends it's put session without sending any more
		// messages
```

PUT session ABORTED by the client during a BASE64 message:

```
	...
	HOST 	--> BASE64 offset bytes ENCODED_CONTENT
	CLIENT  <-- BASE64 offset bytes ENCODED_CONTENT
	CLIENT  --> ABORTED
		// client closes and unlinks its output file
		// and ends it's PUT session
	HOST 	<-- ABORTED
		// host stops sending any more FILE or BASE64 messages.
		// and ends it's put session without sending any more
		// messages
```

PUT session terminated because host gets an error reading the file:

```
	...
	HOST 	--> BASE64 0 0 ERROR - could not read from file
	CLIENT  <-- BASE64 0 0 ERROR - could not read from file
		// At this point the client closes and unlinks its output file
		// Both sides know the PUT session has been terminated.
		// and no more messges will be sent
```

#### PROGRESS messages during a PUT session

The host is the only one who can know how many dirs and files
are being transferred, so it sends the PROGRESS ADD messages.

However, the FILE and BASE64 messages already contain enough
information for the Client to update the progress for
PROGRESS ENTRY, BYTES, and DONE, so the HOST does not
send those messags.

A special case is the SerialSession communicating over a
socket to the windows App.   In this case, the Serial Session
is actualing doing the protocol with the SerialServer,
and generally only forwarding PROGRESS and terminal messages
back to the App.  And so, in that case, it will send
PROGRESS ENTRY, BYTES, and DONE messages back to the App.

### Addition of MKDIR path ts MAY_EXIST==1

An optional param is added to the MKDIR command.
This parameter is only set when MKDIR is called from
a session-like PUT command. It is called (like FILE and
BASE64) and returns OK or an error.
