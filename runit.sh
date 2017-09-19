#!/bin/sh
set -e

# WARNING
#
# These values MUST NOT contain meta characters (for shell, SQL, or regular
# expressions).
DBNAME="token_server_test"
DBDESC="Transient database for token server testing"

TESTCONF="/tmp/token-server-$$.conf"

STACK=$(which stack)

cd $(dirname $0)

# Build first, so we don't wait for the DB only to bail out.
if [ -z "$STACK" ]; then
    cabal build tokenserver
    BIN_DIR=dist/build/tokenserver
else
    stack build
    BIN_DIR=$(stack path --local-install-root)/bin
fi

# Clean up our mess from last time
dropdb -U postgres --if-exists $DBNAME

createdb -U postgres $DBNAME "$DBDESC"

psql $DBNAME postgres < schema/postgresql.sql
psql $DBNAME postgres < examples/postgresql-data.sql

cat examples/token-server.conf \
| sed -e "s/DBNAME/$DBNAME/" \
> $TESTCONF

# Trap the interrupt so that we can clean up.
trap "echo interrupted" INT TERM

$BIN_DIR/tokenserver "$TESTCONF"

# Clean up our mess
echo "Cleaning up!"
dropdb -U postgres $DBNAME
rm $TESTCONF
