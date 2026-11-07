#!/usr/bin/env bash
# Runner uji backend SendFood di PostgreSQL lokal sekali pakai.
#
# Mode default: menjalankan cluster Postgres sementara (socket unix saja, tanpa TCP)
# di direktori temporer, membuat database sendfood_test_*, menerapkan shim Supabase,
# semua migrasi sesuai urutan nama, verify_schema.sql, lalu tes runtime
# (backend/tests/runtime/*.sql), dan menghapus semuanya di akhir.
#
# Mode server sendiri: set SENDFOOD_TEST_PGHOST (hanya localhost/127.0.0.1/::1/path socket),
# SENDFOOD_TEST_PGPORT, SENDFOOD_TEST_PGUSER. Database sendfood_test_* dibuat lalu di-drop.
#
# Biner: PG_BIN=/path/ke/bin, atau psql+initdb di PATH, atau .pgtools (lihat backend/README.md).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/backend/tests"
# shellcheck source=harness/lib.sh
. "$HERE/harness/lib.sh"

PG_BIN_DIR="$(find_pg_bin "$ROOT")" || { echo "Postgres tidak ditemukan. Lihat backend/README.md bagian tes lokal." >&2; exit 2; }
DBNAME="sendfood_test_$(date +%s)_$$"
WORK=""
RUN_PREFIX=()
STARTED=0

cleanup() {
  if [ "$STARTED" = 1 ]; then
    "${RUN_PREFIX[@]}" "$PG_BIN_DIR/pg_ctl" -D "$WORK/data" -m immediate stop >/dev/null 2>&1 || true
  elif [ -n "${PGHOST:-}" ]; then
    "$PG_BIN_DIR/psql" -X -q -d postgres -c "drop database if exists \"$DBNAME\"" >/dev/null 2>&1 || true
  fi
  [ -n "$WORK" ] && rm -rf "$WORK"
}
trap cleanup EXIT

if [ -n "${SENDFOOD_TEST_PGHOST:-}" ]; then
  require_local_host "$SENDFOOD_TEST_PGHOST" || exit 3
  export PGHOST="$SENDFOOD_TEST_PGHOST" PGPORT="${SENDFOOD_TEST_PGPORT:-5432}" PGUSER="${SENDFOOD_TEST_PGUSER:-postgres}"
  "$PG_BIN_DIR/psql" -X -q -d postgres -c "create database \"$DBNAME\"" || exit 2
else
  WORK="$(mktemp -d)"
  if [ "$(id -u)" = 0 ]; then
    # Postgres menolak berjalan sebagai root: jalankan sebagai uid 65534 (nobody).
    chown 65534:65534 "$WORK"
    RUN_PREFIX=(setpriv --reuid=65534 --regid=65534 --clear-groups)
  fi
  "${RUN_PREFIX[@]}" "$PG_BIN_DIR/initdb" -D "$WORK/data" -U postgres -A trust --no-sync >"$WORK/initdb.log" 2>&1 \
    || { cat "$WORK/initdb.log" >&2; exit 2; }
  "${RUN_PREFIX[@]}" "$PG_BIN_DIR/pg_ctl" -D "$WORK/data" -w -l "$WORK/pg.log" \
    -o "-c listen_addresses='' -c unix_socket_directories='$WORK' -c fsync=off -c port=54329" start >/dev/null \
    || { cat "$WORK/pg.log" >&2; exit 2; }
  STARTED=1
  export PGHOST="$WORK" PGPORT=54329 PGUSER=postgres
  "$PG_BIN_DIR/psql" -X -q -d postgres -c "create database \"$DBNAME\"" || exit 2
fi
require_local_host "$PGHOST" || exit 3
export PGDATABASE="$DBNAME"
PSQL=("$PG_BIN_DIR/psql" -X -q -v ON_ERROR_STOP=1)

echo "== Postgres: $("${PSQL[@]}" -At -c 'show server_version') | db: $DBNAME"

echo "== Menerapkan shim Supabase"
"${PSQL[@]}" -f "$HERE/harness/supabase_shim.sql" || { echo "GAGAL: shim"; exit 1; }

for f in "$ROOT"/backend/migrations/*.sql; do
  echo "== Migrasi: $(basename "$f")"
  "${PSQL[@]}" -1 -f "$f" || { echo "GAGAL: migrasi $(basename "$f")"; exit 1; }
done

pass=0; fail=0; skip=0; failed_names=()

# Menghitung baris PASS/FAIL/SKIP dari keluaran sebuah file tes; rc != 0 tanpa FAIL dihitung 1 kegagalan.
tally() {
  local label="$1" rc="$2" out="$3" p f s
  p=$(printf '%s\n' "$out" | grep -c 'NOTICE:  PASS: \|^PASS: ')
  f=$(printf '%s\n' "$out" | grep -c 'NOTICE:  FAIL: \|^FAIL: ')
  s=$(printf '%s\n' "$out" | grep -c 'NOTICE:  SKIP: \|^SKIP: ')
  printf '%s\n' "$out" | grep 'PASS: ' | sed 's/^/  /'
  printf '%s\n' "$out" | grep 'FAIL: \|SKIP: \|CATATAN: ' | sed 's/^/  /'
  pass=$((pass+p)); fail=$((fail+f)); skip=$((skip+s))
  if [ "$rc" -ne 0 ]; then
    fail=$((fail+1)); echo "  GAGAL (exit $rc) $label"
    printf '%s\n' "$out" | grep -v 'PASS: \|SKIP: ' | sed 's/^/    /'
  fi
}

echo "== Struktur: verify_schema.sql"
while IFS='|' read -r name ok; do
  [ -z "$name" ] && continue
  if [ "$ok" = t ]; then pass=$((pass+1)); echo "  ok   $name"; else fail=$((fail+1)); echo "  GAGAL $name"; fi
done < <("$PG_BIN_DIR/psql" -X -q -At -F'|' -f "$HERE/verify_schema.sql")

echo "== Tes runtime (SQL, satu koneksi per file)"
shopt -s nullglob
for f in "$HERE"/runtime/*.sql; do
  echo " -- $(basename "$f")"
  out="$("${PSQL[@]}" -f "$f" 2>&1)"; rc=$?
  tally "$(basename "$f")" "$rc" "$out"
done

echo "== Tes konkurensi (banyak koneksi nyata)"
export PSQL_BIN="$PG_BIN_DIR/psql"
for f in "$HERE"/concurrency/*.sh; do
  echo " -- $(basename "$f")"
  out="$(bash "$f" 2>&1)"; rc=$?
  tally "$(basename "$f")" "$rc" "$out"
done

echo "== Ringkasan: lulus=$pass gagal=$fail dilewati=$skip"
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]
