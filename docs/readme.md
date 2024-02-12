# Pub Perl Libraries

These are my public Perl libraries.

As of this writing the libraries have been run on MSWindows using
a heavily modified ActivePerl 5.12, a stock Strawberry Perl 5.32,
and the rPi stock Perl 5.36.

Some features are platform specific, such as support for Excel only
being available on Windows with the ActivePerl. Another example is
WX which has only been tested on Windows, with both ActivePerl and
Strawberry Perl. The modified WX in my ActivePerl supports a few
additional features (like dropping panes outside the app to create new
new floating frames, and details in wxRichTextControl. However,
in any case, a windows application can be created in Strawberry.
WX has not been tried on the rPi, but I bet it could be made to
work pretty simply, with similar 'limitations'.

The main reason I stick with ActivePerl 5.12 is because it allows
me to to use a vestigial, one-of-a-kind copy of the Cava::Packager,
which no longer exists in any online repositories or source code form,
as Cava::Packager is the only decent solution I ever found for
distributing Perl applications (on Windows only).

Much of the code in these libraries has been ported to base::Pub,
from my existing base::My libraries which are not public.
Care has been taken to never include any credentials, api keys,
certificates, or other security tokens in the Pub repository,
and security is the driving force behind re-creating all my
Perl work from the last several decades.


## 2024-02-10  Rework

The goal is to move My::IOT to Pub::IOT, and along the way
make sure that apps::ebay and apps::inventory make correct
use of Pub.  Eventually rework Artisan to properly use Pub.

By far the most important two packages are

- Utils.pm - contains basic utils for Perl, including
  display routines, string manipulations, etc.
- ServerUtils - basic initialization methods for services
  that must run with no screen output, and/or programs that
  require Wifi


As of this writing Pub is pretty sparse. It contains the following
sub-libraries:

- Excel - WIP for generally using Perl from Excel and vice-versa.
  Currenly used in the WIP apps::inventory program, could in future
  be used in Priv::getBankInfo.
- FS - the 'new' fileServer system, which includes SSL, and is
  associated with apps::fileClient and apps::buddy.
- google::Translate - a thin wrapper around WWW::Google::Translate
  that caches single line translations to spanish in a (SQLite)
  database.
- Socket - test programs only - demonstration of basic client
  server TCP/IP socket architcture with SSL.
- WX - my wrapper around wxPerl for windows applications

The following 'pretty good' packages:

- ComPorts.pm - currently win32 only, enumerates USB comm
  ports, with USB info like names, etc,
- Crypt.pm - a simple RC4 encryptor/decryptor using external
  credentials file.
- PortForwarder.pm - reworked from My::IOT, provides consistent
  port forwading to remove SSH server.
- Pref.pm - simple non-comment preserving prefs text file,
  works with Crypt.pm

That leavs the "problem children", of packages that I want to
clean up and/or replace in this design revision

SQLite.pm - To be replaced by Database.pm
  I started down the path of using only SQLite database,
  ala Artisan, but have decided, for the Inventory system, that I
  want the old complex database, which included Postgres and mySQL
  as well (minus vfOLEDB), particularly for its ability to read
  and write text files (do backups and restore them).
HTTPServer.pm and httpUtils.pm - to be replaced with HTTP subfolder.
  These are vestigial Artisan-like things that are currently only
  used in the Inventory app.  I want to nip this approach in the
  bud.  All HTTP Servers should be the same, and eventually
  Artisan reworked to use Pub::HTTP (Request and Response).
SSDPScan.pm - currently used in Buddy.  I have to think about
  this. Artisan currently has the best oveerall SSDP
  implementation for an actual UPNP Service.  Buddy's usage
  is somewhat simpler .. it currently just wants to scan
  for myIOT devices that advertise themselves via SSDP.




### Database

	Start by just copying verbatim.
	No credentials are present in code.

### HTTP

	Start by just copying verbatim and cleaning up to uppercase
	params including SSL.  Requires Users.pm

### SSDP

	Starting with the Artisan SSDP.pm.
	'Search' for Buddy could be shoe-horned into new() as a short lived 'server'.
	Seems like, for a server, it should 'know' the XML stuff and work directly
	with HTTP::ServerBase

### Users

	myIOT requires a users.txt file known by HTTP.
	This will require a new /dat/Private/vault with
	known credentials file.

### Certificates

	As with fileServer.pm, at this time I am the only person
	able to acces MY SSL secured myIOT Server.  The difference
	with myIOT is that it gets hit from a browser, which requires
	domain name validation.  I am going to try * to
	allow one certificate to be used with any of my applications.







## License

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License Version 3 as published by
the Free Software Foundation.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

Please see **LICENSE.TXT** for more information.

---- end of readme ----
