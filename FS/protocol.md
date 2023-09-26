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
- DELETE		dir [single_filename | (ENTRY_LIST)]

- XFER			is_local dir target_dir [single_file_name | (ENTRY_LIST)]
- GET           dir filename
- PUT			dir (FILE_ENTRY)
- CONTINUE
- BASE64		offset bytes content


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

The PUT packet is multiple lines with the first line containing
the dir param, and the next line being a FILE_ENTRY for the PUT.


### ENTRY_LIST, DIR_LIST, DIR_ENTRY, and FILE_ENTRY

In addition to the above packets which explicitly start with a protocol
*verb*, final command *reply packets* typicially consist of a text
representation of a directory listing or an entry within a directory
listing.

A DIR_ENTRY is a tab delimited line of text consisting of three fields:

- the **size** of a file, blank for directories
- the **timestamp** of a file or directory
- the **name** of the file, or the name of the directory terminated with '/'

If the name is not terminated with '/', the DIR_ENTRY can be considered
to be a FILE_ENTRY.

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
- MKDIR			dir name
- DELETE		dir (single_filename | entry_list]


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


### Asynchronous Commands

The XFER and 'DELETE ENTRY_LIST' commands can take
a long time, can retun intermediate PROGRESS messages,
and can be ABORTED.

Upon final success they return a DIR_LIST.

PROGRESS messages are sent from the Server to the Client to
give the client information needed to update a progress dialog.

	PROGRESS ADD	num_dirs num_files  // adds dirs and files to progress range
	PROGRESS DONE   is_dir              // increments num_done for dirs and files
	PROGRESS ENTRY  entry  [size]       // displays the path or filename. sets the range if [size] or hides guage if not
	// PROGRESS SIZE   size/            // no longer separate
	PROGRESS BYTES  bytes               // set the value for the 2nd bytes transferred gauge

ABORT can be sent by the Client to stop an asyncrhonous command,
which case the Server returns ABORTED to acknowledge the cessation
has taken place.
