#!/usr/bin/env bash
# Tes konkurensi batas 10 alamat per customer (koneksi psql nyata, role authenticated lewat t.login).
# Dipanggil oleh backend/tests/run.sh (PGHOST/PGDATABASE/PSQL_BIN sudah di-export).
set -uo pipefail
: "${PSQL_BIN:?dipanggil lewat run.sh}"
case "${PGDATABASE:-}" in sendfood_test_*) ;; *) echo "FAIL: guard (database bukan sendfood_test_*)"; exit 2 ;; esac

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
P=("$PSQL_BIN" -X -q -At)
CUST_A=10000000-0000-0000-0000-00000000000a
CUST_B=10000000-0000-0000-0000-00000000000b

q() { "${P[@]}" -c "$1"; }
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 ($2)"; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "diharapkan '$3', didapat '$2'"; fi; }
cnt() { q "select count(*) from public.customer_addresses where customer_id='$1'"; }

cleanup() { q "delete from public.customer_addresses where customer_id in ('$CUST_A','$CUST_B')" >/dev/null; }
seed() { q "insert into public.customer_addresses (customer_id, label, address) select '$1', 'seed'||i, 'Jl. '||i from generate_series(1,$2) i" >/dev/null; }

# ins_sql <customer> <label> <hold-seconds> <commit|rollback>
ins_sql() {
  cat <<SQL
begin;
select t.login('$1');
insert into public.customer_addresses (label, address) values ('$2', 'Jl. $2');
select pg_sleep($3);
$4;
SQL
}
errs() { cat "$@" | grep -c 'address_limit_reached'; }
other_errs() { cat "$@" | grep -i "error:" | grep -v "address_limit_reached" | wc -l; }

cleanup

# --- A1: 9 alamat, 2 INSERT bersamaan ---
seed $CUST_A 9
ins_sql $CUST_A race1 1.5 commit > "$TMP/a1_1.sql"
ins_sql $CUST_A race2 0 commit > "$TMP/a1_2.sql"
( "${P[@]}" -f "$TMP/a1_1.sql" > "$TMP/a1_1.out" 2>&1 ) &
sleep 0.4
( "${P[@]}" -f "$TMP/a1_2.sql" > "$TMP/a1_2.out" 2>&1 ) &
wait
check "alamat konkuren: 9 alamat + 2 INSERT bersamaan berakhir tepat 10" "$(cnt $CUST_A)" 10
check "alamat konkuren: tepat satu INSERT ditolak address_limit_reached" "$(errs "$TMP"/a1_*.out)" 1
oe="$(cat "$TMP"/a1_*.out | grep -i "error:" | grep -v "address_limit_reached\|current transaction is aborted")"
check "alamat konkuren: tidak ada error lain (mis. deadlock)" "$oe" ""
cleanup

# --- A2: 9 alamat, 4 INSERT bersamaan ---
seed $CUST_A 9
for i in 1 2 3 4; do ins_sql $CUST_A multi$i "$([ $i = 1 ] && echo 1.5 || echo 0)" commit > "$TMP/a2_$i.sql"; done
for i in 1 2 3 4; do ( "${P[@]}" -f "$TMP/a2_$i.sql" > "$TMP/a2_$i.out" 2>&1 ) & sleep 0.2; done
wait
check "alamat konkuren: 4 INSERT bersamaan pada 9 alamat berakhir tepat 10" "$(cnt $CUST_A)" 10
check "alamat konkuren: 3 dari 4 INSERT ditolak address_limit_reached" "$(errs "$TMP"/a2_*.out)" 3
check "alamat konkuren: tidak ada deadlock pada 4 INSERT" "$(cat "$TMP"/a2_*.out | grep -ci deadlock)" 0
cleanup

# --- A3: batas sequential ---
seed $CUST_A 9
q "select 1" >/dev/null
ins_sql $CUST_A seq10 0 commit > "$TMP/a3_1.sql"
ins_sql $CUST_A seq11 0 commit > "$TMP/a3_2.sql"
"${P[@]}" -f "$TMP/a3_1.sql" > "$TMP/a3_1.out" 2>&1
"${P[@]}" -f "$TMP/a3_2.sql" > "$TMP/a3_2.out" 2>&1
check "alamat sequential: INSERT ke-10 berhasil" "$(errs "$TMP/a3_1.out")" 0
check "alamat sequential: INSERT ke-11 ditolak address_limit_reached" "$(errs "$TMP/a3_2.out")" 1
check "alamat sequential: jumlah akhir tetap 10" "$(cnt $CUST_A)" 10
cleanup

# --- A4: isolasi customer berbeda (lock per customer, bukan global) ---
seed $CUST_A 9
ins_sql $CUST_A iso_a 2 commit > "$TMP/a4_a.sql"
ins_sql $CUST_B iso_b 0 commit > "$TMP/a4_b.sql"
( "${P[@]}" -f "$TMP/a4_a.sql" > "$TMP/a4_a.out" 2>&1 ) &
sleep 0.6
t0=$(date +%s.%N)
"${P[@]}" -f "$TMP/a4_b.sql" > "$TMP/a4_b.out" 2>&1
t1=$(date +%s.%N)
wait
quick=$(awk -v a="$t0" -v b="$t1" 'BEGIN{print (b-a < 1.0) ? "tidak-menunggu" : "menunggu"}')
check "alamat isolasi: INSERT customer lain tidak menunggu lock customer A" "$quick" tidak-menunggu
check "alamat isolasi: kedua customer berhasil (A=10, B=1)" "$(cnt $CUST_A),$(cnt $CUST_B)" 10,1
check "alamat isolasi: tidak ada error" "$(cat "$TMP"/a4_*.out | grep -ci error)" 0
cleanup

# --- A5: rollback membebaskan slot; pesaing menunggu lalu berhasil ---
seed $CUST_A 9
ins_sql $CUST_A rb1 1.5 rollback > "$TMP/a5_1.sql"
ins_sql $CUST_A rb2 0 commit > "$TMP/a5_2.sql"
( "${P[@]}" -f "$TMP/a5_1.sql" > "$TMP/a5_1.out" 2>&1 ) &
sleep 0.4
t0=$(date +%s.%N)
( "${P[@]}" -f "$TMP/a5_2.sql" > "$TMP/a5_2.out" 2>&1 ) &
wait
t1=$(date +%s.%N)
w=$(awk -v a="$t0" -v b="$t1" 'BEGIN{print (b-a >= 0.8) ? "menunggu" : "tidak-menunggu"}')
check "alamat rollback: INSERT kedua menunggu transaksi pertama" "$w" menunggu
check "alamat rollback: setelah rollback, INSERT kedua berhasil (total 10)" "$(cnt $CUST_A)" 10
check "alamat rollback: baris yang di-rollback tidak ada" "$(q "select count(*) from public.customer_addresses where label='rb1'")" 0
check "alamat rollback: tidak ada error" "$(cat "$TMP"/a5_*.out | grep -ci error)" 0
cleanup
