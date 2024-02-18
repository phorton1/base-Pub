#!/usr/bin/perl
#--------------------------------------------------------
# Pub::DatabaseDefs
#-------------------------------------------------------
# Low level constants for use by Pub::Database and clients

package Pub::DatabaseDefs;
use strict;
use warnings;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (

		$STANDARD_ID_FIELD_TYPE
        $STANDARD_ID_FIELD

		$DATE_STORAGE_SIZE
		$DB_FIELD_TYPE_DATE
		$DB_FIELD_DEF_DATE

		$DATETIME_STORAGE_SIZE
		$DB_FIELD_TYPE_DATETIME
		$DB_FIELD_DEF_DATETIME

    );
}


# The syntax for a auto incrementing integer primary key
# is different across engines.  Our __STANDARD_ID_FIELD__
# is parsed in our Create Table. Use this when the 0th field
# would otherwise not be unique.

our $STANDARD_ID_FIELD_TYPE = '__STANDARD_ID_FIELD__';
our $STANDARD_ID_FIELD = "id  $STANDARD_ID_FIELD_TYPE";

our $DATE_STORAGE_SIZE 	 = 10;
our $DB_FIELD_TYPE_DATE  = "__DATE__";
our $DB_FIELD_DEF_DATE   = "VARCHAR($DATE_STORAGE_SIZE)";

our $DATETIME_STORAGE_SIZE 	 = 26;
our $DB_FIELD_TYPE_DATETIME  = "__DATETIME__";
our $DB_FIELD_DEF_DATETIME  = "VARCHAR($DATETIME_STORAGE_SIZE)";


1;
