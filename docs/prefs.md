# Preferences (and default Folder Structures)

Much of the Pub layer can be driven by preferences stored
in a text file.  Applications and Services can define the
location of that text file which can then subsequently modify
the behavior of the Pub Layer without the Application or
Service, per-se, being aware of, or needing to implement those
preferences.

Typical Perl objects take a set of $params, which can pre-empt
the use of the Prefs by the object, allowing Apps and Services
to redefine the preference for a particular object, or hard-wire
certain non-overridable defaults.

Generally speaking the prefs text files are read-only and are
only loaded at App or Service startup.  User modifiable UserPrefs
are a different thing.


## Default Credentials Folder

By convention the path **/base_data/_ssl** contains any and all
sensitive certificates and keys used by the Pub layer on any given
machine.  This path is by convention, then specified within App or
Service preference files to locate the certificates and keys.

By convention this path not hardwired into the Pub layer in most
code, but there is an exception for the Pub::Crypt key file, which
defaults to /base_data/_ssl/PubCryptKey.txt.

Items within the *_ssl* folder are typically set with
restrictive permissions, like 600 for keys and 640 for
certificates.


## Default Data and Temp Folders

By convention, a given App or Service will have its preference
file in its "data" directory, and files like INI and logfiles
in its "temp" directory.  By convention, the location of these
folders is typically **/base_data/data/Service_or_App_name** and
**/base_data/temp/Service_or_App_name**.

Apps and Services that are Cava::Packaged for delivery of Windows
installers typically use the standard User's Documents and Temp
folders with the Service_or_App_name:

	$ENV{USERPROFILE}."/AppData/Local/Temp".$service_or_app_name
	$ENV{USERPROFILE}."/Documents".$service_or_app_name

so that they do not need to create any new, or have any other
pre-determined outer level folders.  But for apps that I distribute
via Perl, the machines all typically have a "/base_data" outer
level folder that is writable, and that typically has an \_ssl
subdirectory.

Some applications (i.e. my Ebay application, and Artisan) use
completely different data folders, storing persistent data
in specific known directories (i.e. /dat/ebay and /mp3s/_data),
but still making use of the /base_data/temp folder for their
temporary files.


## CRYPT_KEYFILE

One preference is special.  It is used by the Pub::Prefs
code itself to encrypt and decrypt preferences, allowing
for the storage of (limited) things like passwords in
the prefs file, where only the owner of the key can read
and write them.

The key for the Pub::Crypt package must be known, agreed to,
and shared, in certain cases by various applicaitons that
want to share encrypted preferences and make use of the
same Pub::Users text files.

For ease of use, the default for this key file is

	/base_data/_ssl/PubCryptKey.txt

However, Apps and Services can specifically override this in their
initialization code to provide clusters of code that share a
given encryption key.

If a given App or Service does not directly or indirectly
make use of Pub::Crypt, encrypted preferences, or the
Pub::User module, then this preference is not used.



## Similar Preferences

The HTTP::ServerBase and FS::Server are very similar
in that either can make use of SSL certificates and keys,
and/or forward their ports to a remote SSH server.

In order to not assume that an App or Service may only be an
HTTP server OR an FS server, the prefs for these are specifically
named with a prepended **HTTP** or **FS** prefix.


## All Preferences

### Global

- CRYPT_KEYFILE 	= can be specified
- LOGFILE			= TODO


### FS (FS::Server)

- FS_PORT 			= default 5872 or 5873 for SSL
- FS_HOST 			= default undef for all interfaces
- FS_SSL 			= default 0, set to 1 for SSL
- FS_DEBUG_SSL 		= 0..3 default 0
- FS_SSL_CERT_FILE 	= default undef, required if SSL
- FS_SSL_KEY_FILE  	= default undef, required if SSL
- FS_SSL_CA_FILE   	= default undef, optional but highly recommend if SSL
- FS_FWD_PORT 		= default undef, 10203 for SSL FS by convention, drives port forwarding only if SSL
- FS_FWD_USER      	= default undef, required if FWD_PORT
- FS_FWD_SERVER    	= default undef, required if FWD_PORT
- FS_FWD_SSH_PORT  	= default undef, required if FWD_PORT
- FS_FWD_KEYFILE 	= default undef, required if FWD_PORT
- FS_DEBUG_PING		= TODO
- FS_FWD_DEBUG_PING = TODO



### HTTP (HTTP::ServerBase)

Those that are very similar to FS

- HTTP_PORT				= required
- HTTP_HOST 			= TODO
- HTTP_SSL 				= 1 optional
- HTTP_DEBUG_SSL		= TODO
- HTTP_SSL_CERT_FILE  	= default undef, required if SSL
- HTTP_SSL_KEY_FILE  	= default undef, required if SSL
- HTTP_FWD_PORT 		= default undef, drives port forwarding only if SSL
- HTTP_FWD_USER      	= default undef, required if FWD_PORT
- HTTP_FWD_SERVER    	= default undef, required if FWD_PORT
- HTTP_FWD_SSH_PORT  	= default undef, required if FWD_PORT
- HTTP_FWD_KEYFILE 		= default undef, required if FWD_PORT
- HTTP_DEBUG_PING		= TODO
- HTTP_FWD_DEBUG_PING 	= TODO

And those that are specific to the HTTP::ServerBase, starting with the debugging:

- HTTP_DEBUG_SERVER 	= -1..2 default 0
- HTTP_DEBUG_REQUEST 	= 0..5	default 0
- HTTP_DEBUG_RESPONSE 	= 0..5	default 0
- HTTP_DEBUG_QUIET_RE 	= default undef
- HTTP_DEBUG_LOUD_RE 	= default undef
- HTTP_DEBUG_PING 		= 0/1 default 0

HTTP Authorization (Pub::Users text file):

- HTTP_AUTH_FILE      	= drives user authentication
- HTTP_AUTH_REALM     	= required if AUTH_FILE
- HTTP_AUTH_ENCRYPTED 	= 1 optional if AUTH_FILE

Overall HTTP Setup:

- HTTP_SERVER_NAME			= name passed as http Server header in default headers
- HTTP_LOGFILE				= for HTTP separate logfile of HTTP_LOG calls
- HTTP_MAX_THREADS			= default 5
- HTTP_KEEP_ALIVE			= use persistent connections from browsers
- HTTP_DOCUMENT_ROOT 		= $base_dir,
- HTTP_DEFAULT_LOCATION 	= '/index.html'	# used for / requests
- HTTP_ZIP_RESPONSES 	= 1
- HTTP_GET_EXT_RE = 'html|js|css|jpg|png|ico',
- HTTP_SCRIPT_EXT_RE = '',

System Commands

- HTTP_ALLOW_REBOOT   		=> 1				linux only
- HTTP_RESTART_SERVICE  	=> 'artisan'
- HTTP_GIT_UPDATE       	=> '/base/Pub,/base/apps/artisan'




## Pub::IOT (to become apps::myIOTServer)

The myIOTServer is an HTTP Server, so inherits all of the Pub::HTTP
preferences from above.  In addition it has a few of its own specific
preferences:

- SKIP_IOT_TYPES = a regular expression for myIOTDevice types that will be ignored (i.e. 'theClock')

## Artisan

SSDP_FIND_ARTISAN_LIBRARIES	= default(1)
SSDP_FIND_OTHER_LIBRARIES	= default(0)
SSDP_FIND_RENDERERS		 	= not implemented/useful - default(0);


## Inventory System

Takes a command line parameter besides 'no_service' to override
'inventory' with some other name ('rhapsody_inventory' or
'electronics_inventory') as $program_name that will be used
for the standard system directories, preference file, service
and pid filename, as well as the database and tranlsated database.

	/base_data/data/{program_name}
		{program_name}.prefs
		{program_name}.db
		{program_name}_translated.db
	/base_data/temp/{program_name}
		{program_name}.log

Eventually the whole 'standard service setup' can be
encapsulated for Artisan, myEbay, myIOTServer, and
multiple instances of the inventory system, into a single
routine in ServiceMain:

	initServiceMain(program_name);

Preferences and global variables that drive
database Update and Merge functions:

- MASTER_DB_HOST
- MASTER_DB_PORT



## gitUI

- GIT_USER
- GIT_API_TOKEN
- GIT_UPDATE_INTERVAL
- new GIT_REPOS_CONFIG = /base/bat/git_repositories.txt
- new GIT_ID_MAPPING_X = prefs for utils::@id_path_mappings
- new GIT_DISPLAY_IDS_IN_PATHS_WINDOW
- new GIT_DISPLAY_IDS_IN_INFO_WINDOW
- new GIT_INFO_SHOW_COMMIT_DETAILS
- new GIT_EXTERNAL_EDITOR_PATH = $komodo_exe
- new GIT_SHELL_EXTENSIONS = md|gif|png|jpg|jpeg|pdf, in myTextCtrl.pm
- new GIT_EDITOR_EXTENSIONS = txt|pm|pl|ino|cpp|c|h|hpp, in myTextCtrl.pm



---- end of readme ----
