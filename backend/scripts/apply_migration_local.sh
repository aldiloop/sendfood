#!/usr/bin/env bash
# Runner migrasi transaksional dan fail-fast untuk database LOKAL sekali pakai (tes/dev).
#
#   PGHOST=<socket|localhost> PGDATABASE=sendfood_test_x bash backend/scripts/apply_migration_local.sh <file.sql>
#
# Jaminan yang diuji (backend/tests/migration/10_legacy_nan_migration.sh):
# * selalu psql -X -v ON_ERROR_STOP=1 -> error pertama menghentikan eksekusi, exit psql 3;
# * berkas dengan BEGIN/COMMIT sendiri dijalankan apa adanya; berkas tanpa kontrol transaksi
#   (mis. migrasi fondasi yang sudah live dan tidak boleh diubah) dibungkus --single-transaction;
# * gagal di tengah = seluruh berkas di-rollback (skema, katalog, data).
#
# Script ini MENOLAK target non-lokal. Ia bukan alat deploy produksi; penerapan ke Supabase dijelaskan
# di backend/README.md (runbook) dan harus diputuskan operator. Jangan memakai `psql -f` mentah tanpa
# ON_ERROR_STOP: exit code-nya 0 walau ada error.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../tests/harness/lib.sh
. "$ROOT/backend/tests/harness/lib.sh"

f="${1:-}"
[ -n "$f" ] && [ -f "$f" ] || { echo "pemakaian: $0 <berkas-migrasi.sql>" >&2; exit 64; }
require_local_host "${PGHOST:-}" || exit 3
prefix="${SENDFOOD_MIGRATION_ALLOW_DB_PREFIX:-sendfood_}"
case "$prefix" in sendfood_*) ;; *) echo "DITOLAK: prefix database harus diawali sendfood_" >&2; exit 3 ;; esac
case "${PGDATABASE:-}" in
  "$prefix"*) ;;
  *) echo "DITOLAK: PGDATABASE '${PGDATABASE:-}' tidak diawali '$prefix' (hanya DB lokal sekali pakai)." >&2; exit 3 ;;
esac
PG_BIN_DIR="$(find_pg_bin "$ROOT")" || { echo "psql tidak ditemukan" >&2; exit 2; }

# Statement pertama/terakhir (tanpa komentar dan baris kosong).
body="$(sed -e 's/--.*$//' "$f" | tr -s '[:space:]' ' ')"
first="$(printf '%s' "$body" | sed -E 's/^ *//' | cut -c1-6 | tr 'A-Z' 'a-z')"
last="$(printf '%s' "$body" | sed -E 's/ *$//' | rev | cut -c1-7 | rev | tr 'A-Z' 'a-z')"
mode=()
if [ "$first" = "begin;" ] && [ "$last" = "commit;" ]; then
  mode=()            # berkas sudah atomik sendiri (BEGIN ... COMMIT)
elif printf '%s' "$body" | grep -qiE '(^| )(begin|commit|rollback|start transaction) *;'; then
  echo "DITOLAK: $f memakai kontrol transaksi di tengah berkas; tidak bisa dijamin atomik." >&2; exit 65
else
  mode=(--single-transaction)
fi

PGOPTIONS="${PGOPTIONS:-} -c client_min_messages=warning" "$PG_BIN_DIR/psql" -X -q -v ON_ERROR_STOP=1 -v VERBOSITY="${SENDFOOD_MIGRATION_VERBOSITY:-default}" \
  "${mode[@]}" -f "$f"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "MIGRASI GAGAL (exit $rc): $(basename "$f") di-rollback seluruhnya." >&2
fi
exit "$rc"
