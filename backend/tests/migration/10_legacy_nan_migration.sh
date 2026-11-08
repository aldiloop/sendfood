#!/usr/bin/env bash
# Tes migrasi hardening pada database legacy (hanya migrasi fondasi) yang berisi harga NaN.
# Membuktikan: (1) lewat runner terdokumentasi backend/scripts/apply_migration_local.sh migrasi gagal
# tertutup (SQLSTATE 23514, exit 3) dan SELURUH perubahan di-rollback; (2) karena berkas hardening kini
# satu transaksi eksplisit, `psql -f` mentah juga atomik (exit 3 dengan ON_ERROR_STOP; tanpa ON_ERROR_STOP
# exit 0 = kegagalan senyap, tetap di-rollback); (3) migrasi berhasil pada DB legacy bersih; (4) remediasi
# manual pada fixture lokal terpisah lalu migrasi berhasil; (5) lock_timeout membuat migrasi gagal cepat
# (55P03) dan rollback bila tabel terkunci sesi lain.
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
RUNNER="$ROOT/backend/scripts/apply_migration_local.sh"
# run_runner <db> <stdout> <stderr>: jalur terdokumentasi (ON_ERROR_STOP, transaksi tunggal, guard lokal).
run_runner() { PGDATABASE="$1" SENDFOOD_MIGRATION_ALLOW_DB_PREFIX=sendfood_test_ SENDFOOD_MIGRATION_VERBOSITY=verbose PG_BIN="$BIN" bash "$RUNNER" "$HARDENING" >"$2" 2>"$3"; }

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

# ---------- A. Legacy NaN + runner terdokumentasi: gagal tertutup + rollback penuh ----------
mkdb nanfail; DB_A="$MKDB"
seed_legacy "$DB_A" yes
check "legacy: fixture NaN terpasang sebelum migrasi" \
  "$(sql "$DB_A" -At -c "select count(*) from public.products where price = 'NaN'::numeric")" "1"
snap "$DB_A" "$TMP/A.before" "snapshot sebelum" || exit 1

run_runner "$DB_A" "$TMP/A.out" "$TMP/A.err"
rc=$?
note "migrasi hardening pada legacy NaN (runner apply_migration_local.sh): exit=$rc"
check "legacy NaN: runner keluar tepat 3 (ON_ERROR_STOP)" "$rc" "3"
check_nan_error "legacy NaN (runner)" "$TMP/A.err"
if grep -q 'MIGRASI GAGAL (exit 3)' "$TMP/A.err"; then pass "legacy NaN: runner melaporkan kegagalan dan rollback secara eksplisit"; else fail "runner pesan" "tidak ada 'MIGRASI GAGAL (exit 3)'"; fi
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

# ---------- B. psql -f mentah TANPA -1 (dengan ON_ERROR_STOP): kini tetap atomik ----------
mkdb nanraw; DB_B="$MKDB"
seed_legacy "$DB_B" yes
snap "$DB_B" "$TMP/B.before" "snapshot B sebelum" || exit 1
"$PSQL_BIN" -X -q -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -d "$DB_B" -f "$HARDENING" >"$TMP/B.out" 2>"$TMP/B.err"
rcb=$?
snap "$DB_B" "$TMP/B.after" "snapshot B sesudah" || exit 1
note "psql -f TANPA -1 (ON_ERROR_STOP) pada legacy NaN: exit=$rcb"
check "tanpa -1: keluar tepat 3 (ON_ERROR_STOP)" "$rcb" "3"
check_nan_error "tanpa -1" "$TMP/B.err"
if cmp -s "$TMP/B.before.schema" "$TMP/B.after.schema" && cmp -s "$TMP/B.before.catalog" "$TMP/B.after.catalog" \
   && cmp -s "$TMP/B.before.data" "$TMP/B.after.data"; then
  pass "tanpa -1: atomik karena BEGIN/COMMIT di berkas (skema, katalog, data identik)"
else
  fail "tanpa -1: atomisitas" "perubahan parsial tertinggal: $(diff "$TMP/B.before.schema" "$TMP/B.after.schema" | head -4 | tr '\n' ' ')"
fi

# ---------- B2. psql -f mentah TANPA ON_ERROR_STOP: rollback tetapi exit 0 (kegagalan senyap) ----------
mkdb nansilent; DB_B2="$MKDB"
seed_legacy "$DB_B2" yes
snap "$DB_B2" "$TMP/B2.before" "snapshot B2 sebelum" || exit 1
"$PSQL_BIN" -X -q -v VERBOSITY=verbose -d "$DB_B2" -f "$HARDENING" >"$TMP/B2.out" 2>"$TMP/B2.err"
rcb2=$?
snap "$DB_B2" "$TMP/B2.after" "snapshot B2 sesudah" || exit 1
note "psql -f tanpa ON_ERROR_STOP: exit=$rcb2 (psql tidak menandai error lewat exit code)"
check "tanpa ON_ERROR_STOP: exit 0 walau gagal (alasan runner mewajibkan ON_ERROR_STOP)" "$rcb2" "0"
check_nan_error "tanpa ON_ERROR_STOP" "$TMP/B2.err"
if grep -q 'current transaction is aborted' "$TMP/B2.err"; then pass "tanpa ON_ERROR_STOP: statement sesudah error ditolak (transaksi aborted)"; else fail "tanpa ON_ERROR_STOP" "tidak ada 'current transaction is aborted'"; fi
if cmp -s "$TMP/B2.before.schema" "$TMP/B2.after.schema" && cmp -s "$TMP/B2.before.catalog" "$TMP/B2.after.catalog" \
   && cmp -s "$TMP/B2.before.data" "$TMP/B2.after.data"; then
  pass "tanpa ON_ERROR_STOP: COMMIT menjadi ROLLBACK, skema/katalog/data identik"
else
  fail "tanpa ON_ERROR_STOP: atomisitas" "berubah"
fi

# ---------- C. Legacy bersih: migrasi berhasil ----------
mkdb clean; DB_C="$MKDB"
seed_legacy "$DB_C" no
snap "$DB_C" "$TMP/C.before" "snapshot C sebelum" || exit 1
run_runner "$DB_C" "$TMP/C.out" "$TMP/C.err"
rcc=$?
note "migrasi hardening pada legacy bersih (runner): exit=$rcc"
check "legacy bersih: migrasi hardening exit 0" "$rcc" "0"
check "legacy bersih: tidak ada ERROR di stderr (NOTICE 'does not exist, skipping' wajar)" "$(grep -c 'ERROR' "$TMP/C.err")" "0"
check "legacy bersih: constraint products_price_not_nan ada dan tervalidasi" \
  "$(sql "$DB_C" -At -c "select count(*) from pg_constraint where conrelid='public.products'::regclass and conname='products_price_not_nan' and contype='c' and convalidated")" "1"
check "legacy bersih: create_order memuat guard invalid_product_price" \
  "$(sql "$DB_C" -At -c "select (pg_get_functiondef(p.oid) like '%invalid_product_price%')::text from pg_proc p where p.proname='create_order' and p.pronamespace='public'::regnamespace")" "true"
check "legacy bersih: migrasi TIDAK membuat default completion_actor (fail-closed)" \
  "$(sql "$DB_C" -At -c "select count(*) from public.ops_policy where key = 'completion_actor'")" "0"
check "legacy bersih: kebijakan lain default tertutup" \
  "$(sql "$DB_C" -At -c "select string_agg(key||'='||value, ',' order by key) from public.ops_policy")" \
  "cancellation_enabled=false,cod_collection_recording_enabled=false,manual_transfer_enabled=false"
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
run_runner "$DB_D" "$TMP/D.out" "$TMP/D.err"
check "remediasi fixture: migrasi hardening exit 0 setelah remediasi" "$?" "0"
check "remediasi fixture: constraint terpasang" \
  "$(sql "$DB_D" -At -c "select count(*) from pg_constraint where conname='products_price_not_nan' and convalidated")" "1"

# ---------- E. Fail-fast: tabel products dikunci sesi lain -> lock_timeout 55P03 dan rollback ----------
mkdb locked; DB_E="$MKDB"
seed_legacy "$DB_E" no
snap "$DB_E" "$TMP/E.before" "snapshot E sebelum" || exit 1
# Sesi lain memegang ACCESS EXCLUSIVE pada products selama 30 detik (dibatalkan setelah migrasi selesai).
"$PSQL_BIN" -X -q -d "$DB_E" -c "begin; lock table public.products in access exclusive mode; select pg_sleep(30); commit;" >/dev/null 2>&1 &
LOCKER=$!
for i in $(seq 1 50); do
  [ "$(sql "$DB_E" -At -c "select count(*) from pg_locks l join pg_class c on c.oid=l.relation where c.relname='products' and l.mode='AccessExclusiveLock' and l.granted")" = 1 ] && break
  sleep 0.1
done
t0=$(date +%s)
run_runner "$DB_E" "$TMP/E.out" "$TMP/E.err"
rce=$?; t1=$(date +%s)
kill "$LOCKER" >/dev/null 2>&1; wait "$LOCKER" 2>/dev/null
sql "$DB_E" -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = current_database() and pid <> pg_backend_pid()" >/dev/null
note "migrasi saat products terkunci: exit=$rce dalam $((t1-t0)) detik; $(grep -m1 'ERROR:' "$TMP/E.err")"
check "lock: runner keluar tepat 3" "$rce" "3"
if grep -q 'ERROR:  55P03:' "$TMP/E.err"; then pass "lock: gagal cepat dengan SQLSTATE 55P03 (lock_timeout)"; else fail "lock: SQLSTATE" "$(tr '\n' ' ' < "$TMP/E.err" | cut -c1-300)"; fi
if [ $((t1-t0)) -lt 25 ]; then pass "lock: tidak menunggu kunci sampai selesai (< 25 detik)"; else fail "lock: durasi" "$((t1-t0)) detik"; fi
snap "$DB_E" "$TMP/E.after" "snapshot E sesudah" || exit 1
if cmp -s "$TMP/E.before.schema" "$TMP/E.after.schema" && cmp -s "$TMP/E.before.catalog" "$TMP/E.after.catalog"; then
  pass "lock: skema dan katalog identik (rollback penuh)"; else fail "lock: rollback" "berubah"; fi

# ---------- F. Guard runner: target bukan DB tes ditolak sebelum menyentuh database ----------
PGDATABASE=postgres SENDFOOD_MIGRATION_ALLOW_DB_PREFIX=sendfood_test_ PG_BIN="$BIN" bash "$RUNNER" "$HARDENING" >"$TMP/F.out" 2>"$TMP/F.err"
check "guard: runner menolak database non-sendfood_test_ (exit 3)" "$?" "3"
PGHOST=db.example.com PGDATABASE=sendfood_test_x PG_BIN="$BIN" bash "$RUNNER" "$HARDENING" >"$TMP/F2.out" 2>"$TMP/F2.err"
check "guard: runner menolak host non-lokal (exit 3)" "$?" "3"
check "guard: tidak ada migrasi hardening di database postgres" \
  "$("$PSQL_BIN" -X -q -At -d postgres -c "select count(*) from pg_class where relname='ops_policy'")" "0"

# ---------- G. Legacy toko dengan delivery_fee/service_radius_km NaN: gagal tertutup, rollback, data tidak diubah ----------
for col in delivery_fee service_radius_km; do
  mkdb "store${col%%_*}"; DB_G="$MKDB"
  seed_legacy "$DB_G" no
  sql "$DB_G" -c "update public.stores set delivery_fee = 5000, service_radius_km = 5, latitude = -6.2, longitude = 106.8
      where id = '22222222-2222-2222-2222-222222222222';
    update public.stores set $col = 'NaN' where id = '22222222-2222-2222-2222-222222222222'" >/dev/null || exit 2
  snap "$DB_G" "$TMP/G$col.before" "snapshot G $col sebelum" || exit 1
  run_runner "$DB_G" "$TMP/G$col.out" "$TMP/G$col.err"
  rcg=$?
  case "$col" in delivery_fee) cname=stores_delivery_fee_not_nan ;; *) cname=stores_service_radius_not_nan ;; esac
  check "legacy $col NaN: runner keluar tepat 3" "$rcg" "3"
  line="$(grep -m1 "ERROR:  23514:.*$cname" "$TMP/G$col.err")"
  if [ -n "$line" ]; then pass "legacy $col NaN: baris ERROR memuat 23514 dan $cname"; note "legacy $col NaN baris ERROR asli: $line"
  else fail "legacy $col NaN: baris ERROR" "$(tr '\n' ' ' < "$TMP/G$col.err" | cut -c1-400)"; fi
  snap "$DB_G" "$TMP/G$col.after" "snapshot G $col sesudah" || exit 1
  if cmp -s "$TMP/G$col.before.schema" "$TMP/G$col.after.schema" && cmp -s "$TMP/G$col.before.catalog" "$TMP/G$col.after.catalog" \
     && cmp -s "$TMP/G$col.before.data" "$TMP/G$col.after.data"; then
    pass "legacy $col NaN: skema/katalog/data identik (rollback penuh, baris legacy tidak diubah)"
  else fail "legacy $col NaN: rollback" "berubah"; fi
  check "legacy $col NaN: nilai NaN legacy tetap ada" \
    "$(sql "$DB_G" -At -c "select count(*) from public.stores where $col = 'NaN'::numeric")" "1"
done

# ---------- H. Runner: kontrol transaksi top-level divalidasi SEBELUM eksekusi ----------
# Bug sebelumnya (8429a92): berkas `BEGIN;..COMMIT; BEGIN;..ERROR;COMMIT;` lolos dan meninggalkan commit parsial.
mkdb runner; DB_H="$MKDB"
runner_on() { PGDATABASE="$DB_H" SENDFOOD_MIGRATION_ALLOW_DB_PREFIX=sendfood_test_ PG_BIN="$BIN" bash "$RUNNER" "$1" >"$1.out" 2>"$1.err"; }
left() { sql "$DB_H" -At -c "select coalesce(string_agg(relname, ',' order by relname), 'none') from pg_class where relname like 'rx\_%'"; }
H="$TMP/rx"; mkdir -p "$H"
printf 'begin;\ncreate table public.rx_a(x int);\ncommit;\nbegin;\ncreate table public.rx_b(x int);\nselect 1/0;\ncommit;\n' > "$H/two_tx.sql"
printf 'begin;\ncreate table public.rx_c(x int);\ncommit;\ncreate table public.rx_d(x int);\n' > "$H/commit_mid.sql"
printf 'begin;\ncreate table public.rx_e(x int);\nsavepoint s1;\nrollback to savepoint s1;\ncommit;\n' > "$H/savepoint.sql"
printf 'begin;\ncreate table public.rx_f(x int);\nend;\n' > "$H/end_kw.sql"
printf 'create table public.rx_g(x int);\ncommit;\n' > "$H/commit_only.sql"
printf 'create table public.rx_h(x int);\n\\! echo meta\n' > "$H/meta.sql"
printf 'create function public.rx_fn() returns int language sql begin atomic select 1; end;\n' > "$H/atomic.sql"
for c in two_tx commit_mid savepoint end_kw commit_only meta atomic; do
  runner_on "$H/$c.sql"; rc=$?
  check "runner: berkas $c ditolak exit 65 sebelum eksekusi" "$rc" "65"
  if grep -q 'DITOLAK' "$H/$c.sql.err"; then pass "runner: $c pesan DITOLAK"; else fail "runner: $c pesan" "$(tr '\n' ' ' < "$H/$c.sql.err" | cut -c1-200)"; fi
done
check "runner: tidak ada tabel tertinggal dari berkas yang ditolak" "$(left)" "none"
note "runner two_tx: $(tr '\n' ' ' < "$H/two_tx.sql.err")"

# Jebakan: BEGIN/COMMIT/END di komentar, string, identifier ber-kutip, dollar-quote dan body PL/pgSQL BUKAN kontrol transaksi.
cat > "$H/tricky_ok.sql" <<'SQL'
-- komentar: begin; commit;
/* komentar /* bersarang: commit; */ end; */
create table public.rx_ok(x text, "commit;" int);
insert into public.rx_ok(x) values ('begin; commit; end;'), (E'it\'s; commit;');
create function public.rx_okfn() returns int language plpgsql as $fn$
begin
  -- commit; di dalam body
  return 1;
end;
$fn$;
do $$ begin perform 1; end $$;
SQL
runner_on "$H/tricky_ok.sql"; rc=$?
check "runner: jebakan (komentar/string/dollar-quote) diterima dan berhasil" "$rc" "0"
check "runner: jebakan membuat objek yang benar" \
  "$(sql "$DB_H" -At -c "select count(*)||'/'||(select public.rx_okfn()) from public.rx_ok")" "2/1"
sql "$DB_H" -c "drop table public.rx_ok; drop function public.rx_okfn();" >/dev/null
sed 's/^do \$\$ begin perform 1; end \$\$;$/do $$ begin perform 1; end $$;\nselect 1\/0;/' "$H/tricky_ok.sql" > "$H/tricky_fail.sql"
runner_on "$H/tricky_fail.sql"; rc=$?
check "runner: jebakan + error di akhir keluar 3" "$rc" "3"
check "runner: jebakan + error di-rollback seluruhnya (dibungkus satu transaksi)" "$(left)" "none"
check "runner: fungsi jebakan tidak tertinggal" "$(sql "$DB_H" -At -c "select count(*) from pg_proc where proname='rx_okfn'")" "0"

# Berkas own (BEGIN pertama + COMMIT terakhir) dengan error di tengah -> rollback penuh.
printf 'begin;\ncreate table public.rx_own(x int);\ninsert into public.rx_own values (1);\nselect 1/0;\ncommit;\n' > "$H/own_fail.sql"
runner_on "$H/own_fail.sql"; rc=$?
check "runner: berkas own gagal keluar 3" "$rc" "3"
check "runner: berkas own gagal tidak meninggalkan tabel" "$(left)" "none"
check "runner: pemindai mengklasifikasi migrasi repo (fondasi=wrap, hardening=own)" \
  "$(python3 "$ROOT/backend/scripts/sql_tx_scan.py" "$FOUNDATION")/$(python3 "$ROOT/backend/scripts/sql_tx_scan.py" "$HARDENING")" "wrap/own"
