#!/usr/bin/env bash
# Tes migrasi hardening pada database legacy (hanya migrasi fondasi) yang berisi harga NaN.
# Membuktikan: (1) migrasi gagal tertutup (SQLSTATE 23514, exit non-nol) dan SELURUH perubahan
# di-rollback pada jalur runner `psql -1`; (2) psql tanpa -1 TIDAK atomik (parsial); (3) migrasi
# berhasil pada DB legacy bersih; (4) remediasi manual pada fixture lokal terpisah lalu migrasi berhasil.
# Dipanggil oleh backend/tests/run.sh (PGHOST/PGPORT/PGUSER/PSQL_BIN sudah di-export).
# Semua database dibuat dengan nama sendfood_test_legacy_* dan di-drop di akhir. Tidak menyentuh data produksi.
set -uo pipefail
: "${PSQL_BIN:?dipanggil lewat run.sh}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../harness/lib.sh
. "$HERE/harness/lib.sh"
require_local_host "${PGHOST:-}" || { echo "FAIL: guard host"; exit 2; }
BIN="$(dirname "$PSQL_BIN")"
PG_DUMP="$BIN/pg_dump"
FOUNDATION="$ROOT/backend/migrations/20261107000000_sendfood_backend_foundation.sql"
HARDENING="$ROOT/backend/migrations/20261108000000_sendfood_backend_mvp_hardening.sql"
SHIM="$HERE/harness/supabase_shim.sql"

TMP="$(mktemp -d)"
SUFFIX="$(date +%s)_$$"
DBS=()
cleanup() {
  for d in "${DBS[@]}"; do
    "$PSQL_BIN" -X -q -d postgres -c "drop database if exists \"$d\"" >/dev/null 2>&1 || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 ($2)"; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "diharapkan '$3', didapat '$2'"; fi; }
note() { echo "CATATAN: $1"; }

# Selalu memakai -X -q dan ON_ERROR_STOP. Argumen pertama: nama database.
sql() { local db="$1"; shift; "$PSQL_BIN" -X -q -v ON_ERROR_STOP=1 -d "$db" "$@"; }

mkdb() { # mkdb <nama-pendek> -> mengisi $MKDB (tanpa subshell agar cleanup tahu); berisi shim + migrasi fondasi
  local db="sendfood_test_legacy_${1}_${SUFFIX}"
  case "$db" in sendfood_test_*) ;; *) echo "guard nama db" >&2; exit 2 ;; esac
  "$PSQL_BIN" -X -q -v ON_ERROR_STOP=1 -d postgres -c "create database \"$db\"" || exit 2
  DBS+=("$db")
  sql "$db" -f "$SHIM" >/dev/null || exit 2
  sql "$db" -1 -f "$FOUNDATION" >/dev/null || exit 2
  MKDB="$db"
}

seed_legacy() { # seed_legacy <db> <with_nan:yes|no>
  sql "$1" -c "
    insert into auth.users (id, email) values ('11111111-1111-1111-1111-111111111111','legacy-seller@example.test');
    insert into public.stores (id, owner_id, name, address)
      values ('22222222-2222-2222-2222-222222222222','11111111-1111-1111-1111-111111111111','Toko Legacy','Jl. Legacy 1');
    insert into public.products (id, store_id, name, price) values
      ('33333333-3333-3333-3333-333333333331','22222222-2222-2222-2222-222222222222','Valid',12000);" || exit 2
  if [ "$2" = yes ]; then
    sql "$1" -c "insert into public.products (id, store_id, name, price)
      values ('33333333-3333-3333-3333-333333333332','22222222-2222-2222-2222-222222222222','Legacy NaN','NaN'::numeric);" || exit 2
  fi
}

# Sidik jari: skema (tabel, constraint, fungsi, trigger, policy, grant/ACL, enum) + data semua tabel public.
snapshot() { # snapshot <db> <file>; stderr pg_dump disimpan di <file>.dump*.err
  "$PG_DUMP" -d "$1" --schema-only --no-comments 2>"$2.dump1.err" | grep -v '^\\\(un\)\?restrict ' > "$2.schema" || return 1
  "$PG_DUMP" -d "$1" --data-only --schema=public --inserts --column-inserts 2>"$2.dump2.err" \
    | grep -v '^\\\(un\)\?restrict ' > "$2.data" || return 1
  "$PG_DUMP" -d "$1" --data-only --inserts --column-inserts --table=public.profiles --table=public.stores --table=public.products 2>"$2.dump3.err" \
    | grep -v '^\\\(un\)\?restrict ' > "$2.legacydata" || return 1
  sql "$1" -At -c "
    select 'proc', p.oid::regprocedure::text, md5(pg_get_functiondef(p.oid)), coalesce(p.proacl::text,'')
      from pg_proc p where p.pronamespace = 'public'::regnamespace
    union all select 'con', conrelid::regclass::text || '.' || conname, pg_get_constraintdef(oid), convalidated::text
      from pg_constraint where connamespace = 'public'::regnamespace
    union all select 'rel', c.oid::regclass::text, coalesce(c.relacl::text,''), c.relrowsecurity::text
      from pg_class c where c.relnamespace = 'public'::regnamespace
    union all select 'pol', polrelid::regclass::text || '.' || polname, coalesce(pg_get_expr(polqual, polrelid),''), coalesce(pg_get_expr(polwithcheck, polrelid),'')
      from pg_policy
    union all select 'col', attrelid::regclass::text || '.' || attname, coalesce(attacl::text,''), ''
      from pg_attribute where attrelid in (select oid from pg_class where relnamespace = 'public'::regnamespace) and attnum > 0 and not attisdropped
    order by 1, 2" > "$2.catalog" || return 1
}

# Pembungkus snapshot: bila gagal, cetak stderr pg_dump yang tersimpan.
snap() { # snap <db> <prefix> <label>
  if snapshot "$1" "$2"; then return 0; fi
  fail "$3" "gagal"
  for f in "$2".dump*.err; do [ -s "$f" ] && note "stderr pg_dump ($(basename "$f")): $(tr '\n' ' ' < "$f" | cut -c1-600)"; done
  return 1
}

# Baris ERROR asli (VERBOSITY=verbose) wajib memuat SQLSTATE 23514 DAN nama constraint pada baris yang sama.
nan_errline() { grep -m1 'ERROR:  23514:.*products_price_not_nan' "$1"; }
check_nan_error() { # check_nan_error <label> <stderr-file>
  local line; line="$(nan_errline "$2")"
  if [ -n "$line" ]; then
    pass "$1: satu baris ERROR memuat 'ERROR:  23514:' dan products_price_not_nan"
    note "$1 baris ERROR asli: $line"
    local d; d="$(grep -m1 '^DETAIL:' "$2")"; [ -n "$d" ] && note "$1 $d"
  else
    fail "$1: baris ERROR" "tidak ada baris ERROR dengan 23514 dan products_price_not_nan; stderr: $(tr '\n' ' ' < "$2" | cut -c1-600)"
  fi
}

echo "== Versi: $("$PSQL_BIN" -X -q -At -d postgres -c 'show server_version')"

# ---------- A. Legacy NaN + runner terdokumentasi (psql -1): gagal tertutup + rollback penuh ----------
mkdb nanfail; DB_A="$MKDB"
seed_legacy "$DB_A" yes
check "legacy: fixture NaN terpasang sebelum migrasi" \
  "$(sql "$DB_A" -At -c "select count(*) from public.products where price = 'NaN'::numeric")" "1"
snap "$DB_A" "$TMP/A.before" "snapshot sebelum" || exit 1

"$PSQL_BIN" -X -q -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -d "$DB_A" -1 -f "$HARDENING" >"$TMP/A.out" 2>"$TMP/A.err"
rc=$?
note "migrasi hardening pada legacy NaN (psql -1): exit=$rc"
check "legacy NaN: migrasi hardening keluar tepat 3 (ON_ERROR_STOP)" "$rc" "3"
check_nan_error "legacy NaN (psql -1)" "$TMP/A.err"
snap "$DB_A" "$TMP/A.after" "snapshot sesudah" || exit 1
if cmp -s "$TMP/A.before.schema" "$TMP/A.after.schema"; then pass "rollback: dump skema (tabel/fungsi/trigger/policy/grant) identik sebelum/sesudah"; else fail "rollback: skema" "berbeda: $(diff "$TMP/A.before.schema" "$TMP/A.after.schema" | head -5 | tr '\n' ' ')"; fi
if cmp -s "$TMP/A.before.data" "$TMP/A.after.data"; then pass "rollback: data baris legacy (termasuk NaN) identik sebelum/sesudah"; else fail "rollback: data" "berbeda"; fi
if cmp -s "$TMP/A.before.catalog" "$TMP/A.after.catalog"; then pass "rollback: katalog fungsi/constraint/grant/policy identik sebelum/sesudah"; else fail "rollback: katalog" "berbeda: $(diff "$TMP/A.before.catalog" "$TMP/A.after.catalog" | head -5 | tr '\n' ' ')"; fi
note "sha256 skema sebelum=$(sha256sum < "$TMP/A.before.schema" | cut -c1-16) sesudah=$(sha256sum < "$TMP/A.after.schema" | cut -c1-16); katalog sebelum=$(sha256sum < "$TMP/A.before.catalog" | cut -c1-16) sesudah=$(sha256sum < "$TMP/A.after.catalog" | cut -c1-16); baris katalog=$(wc -l < "$TMP/A.after.catalog")"
check "rollback: constraint products_price_not_nan tidak ada" \
  "$(sql "$DB_A" -At -c "select count(*) from pg_constraint where conname = 'products_price_not_nan'")" "0"
check "rollback: baris legacy NaN masih ada dan tidak diubah/dihapus otomatis" \
  "$(sql "$DB_A" -At -c "select count(*) from public.products where price = 'NaN'::numeric")" "1"
check "rollback: create_order tetap versi fondasi (tanpa guard invalid_product_price)" \
  "$(sql "$DB_A" -At -c "select (pg_get_functiondef(p.oid) like '%invalid_product_price%')::text from pg_proc p where p.proname='create_order' and p.pronamespace='public'::regnamespace")" "false"

# ---------- B. Pembanding: psql TANPA -1 tidak atomik ----------
mkdb nanraw; DB_B="$MKDB"
seed_legacy "$DB_B" yes
snap "$DB_B" "$TMP/B.before" "snapshot B sebelum" || exit 1
"$PSQL_BIN" -X -q -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -d "$DB_B" -f "$HARDENING" >"$TMP/B.out" 2>"$TMP/B.err"
rcb=$?
snap "$DB_B" "$TMP/B.after" "snapshot B sesudah" || exit 1
note "psql TANPA -1 pada legacy NaN: exit=$rcb"
check "tanpa -1: keluar tepat 3 (ON_ERROR_STOP)" "$rcb" "3"
check_nan_error "tanpa -1" "$TMP/B.err"
if cmp -s "$TMP/B.before.schema" "$TMP/B.after.schema"; then
  fail "tanpa -1: dugaan tidak atomik" "skema tidak berubah (ternyata atomik?)"
else
  pass "tanpa -1: TIDAK atomik, perubahan parsial tertinggal (jangan dipakai untuk deploy)"
fi

# ---------- C. Legacy bersih: migrasi berhasil ----------
mkdb clean; DB_C="$MKDB"
seed_legacy "$DB_C" no
snap "$DB_C" "$TMP/C.before" "snapshot C sebelum" || exit 1
"$PSQL_BIN" -X -q -v ON_ERROR_STOP=1 -d "$DB_C" -1 -f "$HARDENING" >"$TMP/C.out" 2>"$TMP/C.err"
rcc=$?
note "migrasi hardening pada legacy bersih (psql -1): exit=$rcc"
check "legacy bersih: migrasi hardening exit 0" "$rcc" "0"
check "legacy bersih: tidak ada ERROR di stderr (NOTICE 'does not exist, skipping' wajar)" "$(grep -c 'ERROR' "$TMP/C.err")" "0"
check "legacy bersih: constraint products_price_not_nan ada dan tervalidasi" \
  "$(sql "$DB_C" -At -c "select count(*) from pg_constraint where conrelid='public.products'::regclass and conname='products_price_not_nan' and contype='c' and convalidated")" "1"
check "legacy bersih: create_order memuat guard invalid_product_price" \
  "$(sql "$DB_C" -At -c "select (pg_get_functiondef(p.oid) like '%invalid_product_price%')::text from pg_proc p where p.proname='create_order' and p.pronamespace='public'::regnamespace")" "true"
check "legacy bersih: baris produk lama tetap (jumlah)" \
  "$(sql "$DB_C" -At -c "select count(*) from public.products")" "1"
check "legacy bersih: harga produk lama tidak berubah" \
  "$(sql "$DB_C" -At -c "select price from public.products where id='33333333-3333-3333-3333-333333333331'")" "12000.00"
snap "$DB_C" "$TMP/C.after" "snapshot C sesudah" || exit 1
if cmp -s "$TMP/C.before.legacydata" "$TMP/C.after.legacydata"; then pass "legacy bersih: dump data profiles/stores/products identik sebelum/sesudah"; else
  note "data berbeda: $(diff "$TMP/C.before.legacydata" "$TMP/C.after.legacydata" | head -4 | tr '\n' ' ')"; fail "legacy bersih: data" "berbeda"; fi
if sql "$DB_C" -c "insert into public.products (store_id,name,price) values ('22222222-2222-2222-2222-222222222222','x','NaN'::numeric)" 2>"$TMP/C.nan.err"; then
  fail "legacy bersih: insert NaN pasca migrasi" "berhasil, seharusnya ditolak"
else
  if grep -q 'products_price_not_nan' "$TMP/C.nan.err"; then pass "legacy bersih: insert NaN pasca migrasi ditolak constraint"; else fail "insert NaN" "pesan tidak sesuai"; fi
fi

# ---------- D. Remediasi manual pada fixture lokal terpisah, lalu migrasi berhasil ----------
mkdb remediated; DB_D="$MKDB"
seed_legacy "$DB_D" yes
# Opsi remediasi contoh (HANYA fixture lokal ini): nonaktifkan produk dan set harga 0 menunggu keputusan pemilik.
sql "$DB_D" -c "update public.products set is_available = false, price = 0 where price = 'NaN'::numeric" >/dev/null
check "remediasi fixture: tidak ada NaN tersisa" "$(sql "$DB_D" -At -c "select count(*) from public.products where price = 'NaN'::numeric")" "0"
"$PSQL_BIN" -X -q -v ON_ERROR_STOP=1 -d "$DB_D" -1 -f "$HARDENING" >"$TMP/D.out" 2>"$TMP/D.err"
check "remediasi fixture: migrasi hardening exit 0 setelah remediasi" "$?" "0"
check "remediasi fixture: constraint terpasang" \
  "$(sql "$DB_D" -At -c "select count(*) from pg_constraint where conname='products_price_not_nan' and convalidated")" "1"
