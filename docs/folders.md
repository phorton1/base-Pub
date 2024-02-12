# Folders

I am standardizing on /base_data/data as the location of persistent configuration files
I need to try restricting the rights on these directories and files

- base_data/_ssl
- base_data/data
  - fileServer/
    - fileServer.prefs
  - myIOTServer/
    - myIOTServer.prefs
	- users.txt
  - buddy/  (windows only)
	  - fileClient.prefs
	  - fileClient.ini
  - gitUI/  (windows only)
	- gitUI.ini
- base_data/temp
  - fileServer.log - the OLD fileServer (6801) log file
  - artisan/
    - artisan.pid (unix only)
    - artisan.log
    - semi persistant caching of artisan state
  - fileServer/
    - fileServer.pid (unix only)
    - fileServer.log (new - 5872/3 logfile)
  - myIOTServer/
	- myIOTServer.pid (unix only)
	- myIOTServer.log
  - gitUI/
	- cache of github repo json requests
  - Rhapsody/
	- google translate built-in cache
	- inventory.log




---- end of readme ----
