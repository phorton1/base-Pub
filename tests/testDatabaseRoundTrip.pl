#!/usr/bin/perl
#-------------------------------------------------------------------------
# tests/testDatabaseRoundTrip.pl
#-------------------------------------------------------------------------
# Regression tests for Pub::Database text backup/restore of multi-line and
# control-char TEXT fields (the _sqlTextLiteral encoding + engine-branched
# INSERT upsert).
#
# Two layers:
#
#   (1) String-level unit tests of _sqlTextLiteral / _insertPrefix /
#       _insertSuffix for all three engines (SQLite, Postgres, MySQL).
#       These need no live database -- they bless a bare {engine=>...}
#       hash and call the method directly, so MySQL is covered here even
#       though no mysqld is required/available.
#
#   (2) Live round-trip tests:
#         - SQLite : always (serverless, temp file DB)
#         - Postgres: if reachable; creates a 'test_pub' database and
#                     DROPS it when finished.
#
# Design decisions under test (locked with Patrick 2026-07-08):
#   (a) preserve ONLY \t \n \r; every other \x00-\x1f char and 0xFF is
#       still stripped (with a warning).
#   (b) full engine portability: SQLite 'INSERT OR REPLACE INTO';
#       Postgres 'INSERT INTO ... ON CONFLICT DO NOTHING';
#       MySQL 'INSERT INTO ... ON DUPLICATE KEY UPDATE col=VALUES(col)'.
#       All three START with INSERT so importDatabase is untouched.
#
# Postgres connection: pass the password via the PGPASSWORD env var (or
# PUB_PG_PASS).  NEVER hardcode it here.  Host/port/user default to
# localhost/5432/postgres and can be overridden with PUB_PG_HOST etc.
#
# Run (from git-bash), capturing output to a file so Pub::Utils' console
# escapes don't corrupt the terminal:
#   PGPASSWORD=... /c/Perl/bin/perl.exe -I/base \
#       /base/Pub/tests/testDatabaseRoundTrip.pl > out.txt 2>&1
#-------------------------------------------------------------------------

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../..";		# C:\base -> finds Pub::*
use Test::More;
use Pub::Utils;
use Pub::DatabaseDefs;
use Pub::Database;

# ---- temp workspace (transient; NOT under the repo) ----

my $TMP = $ENV{PUB_TEST_TMP} || 'C:/_temp/base-Pub';
mkdir($TMP) if !-d $TMP;

# ---- fixtures ----

# NASTY exercises everything that MUST round-trip byte-identically:
# LF, CRLF, a blank line, leading/trailing spaces and a TAB.
my $NASTY =
	"line one\n" .
	"line two\r\n" .
	"\n" .					# blank line
	"  leading and trailing spaces  \n" .
	"a\ttab\there";

# a table definition using the standard auto-increment id (which is NOT
# exported -- the exact condition that makes a Postgres ON CONFLICT target
# unavailable).
my $DEF = {
	things => [
		$STANDARD_ID_FIELD,			# 'id  __STANDARD_ID_FIELD__'
		'name  VARCHAR(64)',
		'body  TEXT',
	],
};


#=========================================================================
# Layer 1: string-level encoding tests (no database)
#=========================================================================

sub lit		# _sqlTextLiteral for a given engine
{
	my ($engine,$val) = @_;
	return bless({engine=>$engine},'Pub::Database')->_sqlTextLiteral($val);
}
sub pfx { bless({engine=>$_[0]},'Pub::Database')->_insertPrefix(); }
sub sfx { bless({engine=>$_[0]},'Pub::Database')->_insertSuffix($_[1]); }

# fast path -- byte-identical to the historical '...' output
is( lit('SQLite','hello'),   "'hello'",     'fast-path plain value' );
is( lit('SQLite',"O'Brien"), "'O''Brien'",  'fast-path quote escaping' );
is( lit('SQLite',''),        "''",          'fast-path empty string' );
is( lit('SQLite','a b  c '), "'a b  c '",   'fast-path preserves spaces' );

# control-char encoding, per engine (value "a\nb")
is( lit('SQLite',"a\nb"), "'a'||char(10)||'b'",
	'sqlite newline -> char(10)' );
is( lit('Pg',"a\nb"), "'a'||chr(10)||'b'",
	'postgres newline -> chr(10)' );
is( lit('mysql',"a\nb"), "CONCAT('a',CHAR(10 USING utf8mb4),'b')",
	'mysql newline -> CONCAT/CHAR USING' );

# tab + cr in one value
is( lit('SQLite',"a\tb\rc"), "'a'||char(9)||'b'||char(13)||'c'",
	'sqlite tab+cr' );

# leading control char (no leading literal run)
is( lit('SQLite',"\nx"), "char(10)||'x'",
	'sqlite leading newline' );
is( lit('mysql',"\nx"), "CONCAT(CHAR(10 USING utf8mb4),'x')",
	'mysql leading newline' );

# quote escaping inside a concat literal run
is( lit('SQLite',"O'B\nx"), "'O''B'||char(10)||'x'",
	'quote escaping within concat run' );

# (a) stripping: ESC, NUL and 0xFF dropped; TAB kept
is( lit('SQLite',"keep\ttab\x1b\x00\xffdrop"), "'keep'||char(9)||'tabdrop'",
	'strip ESC/NUL/0xFF, keep TAB' );

# a value whose only control chars are stripped falls back to plain literal
is( lit('SQLite',"a\x1bb"), "'ab'",
	'strip-only value becomes plain literal' );

# INSERT prefixes
is( pfx('SQLite'), 'INSERT OR REPLACE INTO', 'sqlite prefix' );
is( pfx('Pg'),     'INSERT INTO',            'postgres prefix' );
is( pfx('mysql'),  'INSERT INTO',            'mysql prefix' );

# INSERT suffixes
is( sfx('SQLite',['a','b']), '',
	'sqlite suffix (none)' );
is( sfx('Pg',['a','b']), ' ON CONFLICT DO NOTHING',
	'postgres suffix' );
is( sfx('mysql',['a','b']), ' ON DUPLICATE KEY UPDATE a=VALUES(a),b=VALUES(b)',
	'mysql suffix' );


#=========================================================================
# Layer 2a: live SQLite round-trip
#=========================================================================

{
	my $src = "$TMP/rt_src.db";
	my $txt = "$TMP/rt_backup.txt";
	my $dst = "$TMP/rt_dst.db";
	unlink($src,$txt,$dst);

	my $db = Pub::Database->connect({
		engine => 'SQLite', database => $src, database_def => $DEF });
	ok( $db, 'sqlite: connect source' );
	ok( $db && $db->createTable('things'), 'sqlite: create source table' );
	ok( $db && $db->insert_record('things',{ name=>'row', body=>$NASTY }),
		'sqlite: insert nasty record' );
	ok( $db && $db->exportDatabaseText($txt), 'sqlite: export' );
	$db->disconnect() if $db;

	# import into a brand new (empty) database
	my $db2 = Pub::Database->connect({
		engine => 'SQLite', database => $dst, database_def => $DEF });
	ok( $db2 && $db2->createTable('things'), 'sqlite: create dest table' );
	ok( $db2 && $db2->importDatabase($txt),  'sqlite: import' );
	my $rec = $db2 ? $db2->get_record("SELECT body FROM things") : undef;
	is( $rec && $rec->{body}, $NASTY, 'sqlite: body round-trips byte-identical' );
	$db2->disconnect() if $db2;
}


#=========================================================================
# Layer 2b: backward compat -- a pre-change (plain-literal) backup imports
#=========================================================================

{
	my $old = "$TMP/rt_old_backup.txt";
	my $dst = "$TMP/rt_old_dst.db";
	unlink($old,$dst);

	# exactly the shape old SQLite exports produced: plain '...' literals,
	# INSERT OR REPLACE, ';' on the last tuple line.
	open(my $fh,'>',$old) or die "cannot write $old";
	print $fh "\n\n;\n; TABLE things(2)\n;\n\n";
	print $fh "INSERT OR REPLACE INTO things (name,body) VALUES\n";
	print $fh "('a','plain one'),\n";
	print $fh "('b','plain two');\n";
	print $fh "\n";
	close($fh);

	my $db = Pub::Database->connect({
		engine => 'SQLite', database => $dst, database_def => $DEF });
	ok( $db && $db->createTable('things'), 'oldfile: create table' );
	ok( $db && $db->importDatabase($old),  'oldfile: import pre-change backup' );
	my $recs = $db ? $db->get_records("SELECT body FROM things ORDER BY body") : [];
	is( scalar(@$recs), 2, 'oldfile: both rows imported' );
	is( $recs->[0]{body}, 'plain one', 'oldfile: row 1 body' );
	is( $recs->[1]{body}, 'plain two', 'oldfile: row 2 body' );
	$db->disconnect() if $db;
}


#=========================================================================
# Layer 2c: live Postgres round-trip (creates + drops 'test_pub')
#=========================================================================

my $pg_pass = $ENV{PGPASSWORD} || $ENV{PUB_PG_PASS};
my %pg = (
	host => $ENV{PUB_PG_HOST} || 'localhost',
	port => $ENV{PUB_PG_PORT} || 5432,
	user => $ENV{PUB_PG_USER} || 'postgres',
	password => $pg_pass,
);

SKIP: {
	skip "no Postgres password (set PGPASSWORD)", 6 if !$pg_pass;

	# probe connectivity to the maintenance db first
	my $admin = Pub::Database->connect({
		engine => 'Pg', database => 'postgres', database_def => $DEF, %pg });
	skip "Postgres not reachable", 6 if !$admin;

	# make sure we start clean, then create the test database
	$admin->do("DROP DATABASE IF EXISTS test_pub");
	$admin->disconnect();

	my $db = Pub::Database->createDatabase({
		engine => 'Pg', database => 'test_pub', database_def => $DEF, %pg });
	ok( $db, 'pg: create test_pub database' );

	if ($db)
	{
		ok( $db->createTable('things'), 'pg: create table' );
		ok( $db->insert_record('things',{ name=>'row', body=>$NASTY }),
			'pg: insert nasty record' );
		my $txt = "$TMP/rt_pg_backup.txt";
		unlink($txt);
		ok( $db->exportDatabaseText($txt), 'pg: export' );

		# empty the table, then import back into it (fresh -> no conflicts)
		$db->do("DELETE FROM things");
		ok( $db->importDatabase($txt), 'pg: import' );
		my $rec = $db->get_record("SELECT body FROM things");
		is( $rec && $rec->{body}, $NASTY, 'pg: body round-trips byte-identical' );

		$db->disconnect();
	}

	# tear down: reconnect to maintenance db and drop test_pub
	my $admin2 = Pub::Database->connect({
		engine => 'Pg', database => 'postgres', database_def => $DEF, %pg });
	if ($admin2)
	{
		$admin2->do("DROP DATABASE IF EXISTS test_pub");
		$admin2->disconnect();
	}
}

done_testing();
