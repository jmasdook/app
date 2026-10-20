#!/usr/bin/env bash
# Builds a throw-away database on a LOCAL PostgreSQL, applies the Supabase shim, all migrations,
# the fictional seed, then runs every tests/*.test.sql file and the concurrency test.
# Refuses to run against anything but localhost.  Usage: PGHOST=... PGUSER=... ./run.sh
set -euo pipefail
cd "$(dirname "$0")"
export PGHOST="${PGHOST:-/var/run/postgresql}" PGUSER="${PGUSER:-postgres}" PGPORT="${PGPORT:-5432}"
case "$PGHOST" in localhost|127.0.0.1|/*) ;; *) echo "refusing to run tests against non-local host $PGHOST"; exit 2;; esac
DB="${TEST_DB:-skillconnect_test}"
psql -qX -v ON_ERROR_STOP=1 -d postgres -c "drop database if exists $DB" -c "create database $DB"
P="psql -qX -v ON_ERROR_STOP=1 -d $DB"
$P -f 00_supabase_shim.sql >/dev/null
for f in ../migrations/*.sql; do echo "migrate $(basename "$f")"; $P -f "$f" >/dev/null; done
$P -f ../seed.sql >/dev/null
$P -f 01_helpers.sql >/dev/null
fail=0
for t in *.test.sql; do
  echo "== $t"
  out=$($P -f "$t" 2>&1) && rc=0 || rc=$?
  echo "   passed assertions: $(grep -c 'NOTICE:  ok - ' <<<"$out" || true)"
  grep -v 'NOTICE:  ok - ' <<<"$out" | sed -e '/^$/d' || true
  [ $rc -eq 0 ] || fail=1
done
echo "== concurrency"
DB=$DB bash ./concurrency.sh || fail=1
[ $fail -eq 0 ] && echo "ALL SQL TESTS PASSED" || { echo "SQL TESTS FAILED"; exit 1; }
