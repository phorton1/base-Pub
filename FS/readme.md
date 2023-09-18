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
- PROGRESS		dir name num_dirs num_files dirs_done files_done bytes_file bytes_done
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

- ENABLE msg
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

ABORT is sent by the client to stop an operation, as well as
returned by an operation to acknowledget the cessation.


### DELETE dir entries

Client waits for a DIR_LIST indicating the operation is complete,
while looking for ABORT and processing PROGRESS messages.

Server sends PROGRESS messages as it recurses new directories
and counts their entries, and per each item deleted.











### Timeouts needed

- getPacket
- sendPacket
- doRemoteRequest
