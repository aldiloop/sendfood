#!/usr/bin/env bash
# Tes konkurensi dengan beberapa koneksi psql nyata (proses latar belakang).
# Dipanggil oleh backend/tests/run.sh (PGHOST/PGDATABASE/PSQL_BIN sudah di-export).
# Keluaran: baris "PASS: nama" / "FAIL: nama (detail)" yang dihitung runner.
set -uo pipefail
: "${PSQL_BIN:?dipanggil lewat run.sh}"
case "${PGDATABASE:-}" in sendfood_test_*) ;; *) echo "FAIL: guard (database bukan sendfood_test_*)"; exit 2 ;; esac

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
P=("$PSQL_BIN" -X -q -At)
CUST_A=10000000-0000-0000-0000-00000000000a
CUST_B=10000000-0000-0000-0000-00000000000b
SELLER_A=20000000-0000-0000-0000-00000000000a
ADMIN=40000000-0000-0000-0000-000000000001
STORE_A=50000000-0000-0000-0000-00000000000a
NASI=60000000-0000-0000-0000-0000000000a1
TEH=60000000-0000-0000-0000-0000000000a2

q() { "${P[@]}" -c "$1"; }
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 ($2)"; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "diharapkan '$3', didapat '$2'"; fi; }

# checkout_sql <customer> <product> <qty> <key> <hold-seconds>
checkout_sql() {
  cat <<SQL
begin;
select t.login('$1');
select 'order=' || order_id || ' total=' || total from public.create_order('$STORE_A', '[{"product_id":"$2","quantity":$3}]', 'Jl. X', -6.21, 106.81, null, 'cod', $( [ -n "$4" ] && echo "'$4'" || echo null ));
select pg_sleep($5);
commit;
SQL
}

cleanup() {
  q "delete from public.orders where idempotency_key like 'conc-%'" >/dev/null
  q "update public.products set is_available = true, price = case id when '$NASI' then 10000 when '$TEH' then 4000 end where id in ('$NASI', '$TEH')" >/dev/null
}
cleanup

# --- S1: 4 koneksi, kunci idempotensi sama, customer sama ---
for i in 1 2 3 4; do
  checkout_sql $CUST_A $NASI 2 conc-same-key-1 "$([ $i = 1 ] && echo 1.5 || echo 0)" > "$TMP/s1_$i.sql"
done
for i in 1 2 3 4; do
  ( "${P[@]}" -f "$TMP/s1_$i.sql" > "$TMP/s1_$i.out" 2>&1 ) &
  sleep 0.2
done
wait
n=$(q "select count(*) from public.orders where idempotency_key = 'conc-same-key-1'")
check "konkurensi: 4 checkout bersamaan dengan kunci sama membuat tepat 1 order" "$n" 1
ids=$(cat "$TMP"/s1_*.out | grep -o 'order=[0-9a-f-]*' | sort -u | wc -l)
check "konkurensi: keempat koneksi menerima id order yang sama" "$ids" 1
errs=$(cat "$TMP"/s1_*.out | grep -ci 'error')
check "konkurensi: tidak ada koneksi yang error" "$errs" 0
o=$(q "select id from public.orders where idempotency_key = 'conc-same-key-1'")
check "konkurensi: tepat 1 baris item dan 1 baris riwayat" "$(q "select (select count(*) from public.order_items where order_id='$o') || ',' || (select count(*) from public.order_status_history where order_id='$o')")" "1,1"

# --- S2: checkout menahan lock produk; admin menonaktifkan produk bersamaan ---
checkout_sql $CUST_A $TEH 1 conc-hold-2 2 > "$TMP/s2_a.sql"
cat > "$TMP/s2_b.sql" <<SQL
begin;
select t.login('$ADMIN');
select public.admin_set_product_available('$TEH', false);
commit;
SQL
( "${P[@]}" -f "$TMP/s2_a.sql" > "$TMP/s2_a.out" 2>&1 ) &
sleep 0.6
t0=$(date +%s.%N)
( "${P[@]}" -f "$TMP/s2_b.sql" > "$TMP/s2_b.out" 2>&1 ) &
wait
t1=$(date +%s.%N)
waited=$(awk -v a="$t0" -v b="$t1" 'BEGIN{print (b-a >= 1.0) ? "menunggu" : "tidak-menunggu"}')
check "konkurensi: admin menonaktifkan produk menunggu checkout yang memegang lock produk" "$waited" menunggu
check "konkurensi: checkout yang berjalan lebih dulu berhasil (1 order, total 4000+5000)" "$(q "select count(*) || ',' || coalesce(max(total),0) from public.orders where idempotency_key='conc-hold-2'")" "1,9000.00"
check "konkurensi: setelah commit produk berstatus tidak tersedia" "$(q "select is_available from public.products where id='$TEH'")" f
cat "$TMP/s2_b.out" | grep -qi error && fail "konkurensi: admin_set_product_available tidak error" "$(cat "$TMP/s2_b.out")" || pass "konkurensi: admin_set_product_available selesai tanpa error"
checkout_sql $CUST_B $TEH 1 conc-after-unavail 0 > "$TMP/s2_c.sql"
"${P[@]}" -f "$TMP/s2_c.sql" > "$TMP/s2_c.out" 2>&1
grep -q 'product_unavailable_or_wrong_store' "$TMP/s2_c.out" && pass "konkurensi: checkout setelah produk dinonaktifkan ditolak" || fail "konkurensi: checkout setelah produk dinonaktifkan ditolak" "$(cat "$TMP/s2_c.out")"
check "konkurensi: checkout ditolak tidak meninggalkan order" "$(q "select count(*) from public.orders where idempotency_key='conc-after-unavail'")" 0
cleanup

# --- S3: admin menonaktifkan produk lebih dulu (belum commit); checkout bersamaan ---
cat > "$TMP/s3_a.sql" <<SQL
begin;
select t.login('$ADMIN');
select public.admin_set_product_available('$TEH', false);
select pg_sleep(2);
commit;
SQL
checkout_sql $CUST_B $TEH 1 conc-race-unavail 0 > "$TMP/s3_b.sql"
( "${P[@]}" -f "$TMP/s3_a.sql" > "$TMP/s3_a.out" 2>&1 ) &
sleep 0.6
t0=$(date +%s.%N)
( "${P[@]}" -f "$TMP/s3_b.sql" > "$TMP/s3_b.out" 2>&1 ) &
wait
t1=$(date +%s.%N)
waited=$(awk -v a="$t0" -v b="$t1" 'BEGIN{print (b-a >= 1.0) ? "menunggu" : "tidak-menunggu"}')
check "konkurensi: checkout menunggu perubahan ketersediaan yang belum commit" "$waited" menunggu
grep -q 'product_unavailable_or_wrong_store' "$TMP/s3_b.out" && pass "konkurensi: checkout melihat produk tidak tersedia setelah commit lawan, ditolak konsisten" || fail "konkurensi: checkout melihat produk tidak tersedia" "$(cat "$TMP/s3_b.out")"
check "konkurensi: tidak ada order yatim dari checkout yang kalah" "$(q "select count(*) from public.orders where idempotency_key='conc-race-unavail'")" 0
cleanup

# --- S4: seller mengubah harga saat checkout memegang lock produk ---
checkout_sql $CUST_A $NASI 1 conc-price-race 2 > "$TMP/s4_a.sql"
cat > "$TMP/s4_b.sql" <<SQL
begin;
select t.login('$SELLER_A');
update public.products set price = 20000 where id = '$NASI';
commit;
SQL
( "${P[@]}" -f "$TMP/s4_a.sql" > "$TMP/s4_a.out" 2>&1 ) &
sleep 0.6
( "${P[@]}" -f "$TMP/s4_b.sql" > "$TMP/s4_b.out" 2>&1 ) &
wait
check "konkurensi: snapshot harga order = harga sebelum perubahan konkuren (10000 + ongkir 5000)" "$(q "select total from public.orders where idempotency_key='conc-price-race'")" 15000.00
check "konkurensi: harga produk berubah setelah checkout commit (20000)" "$(q "select price from public.products where id='$NASI'")" 20000.00
check "konkurensi: snapshot item tetap 10000 setelah harga berubah" "$(q "select unit_price_snapshot from public.order_items i join public.orders o on o.id=i.order_id where o.idempotency_key='conc-price-race'")" 10000.00
checkout_sql $CUST_B $NASI 1 conc-price-after 0 > "$TMP/s4_c.sql"
"${P[@]}" -f "$TMP/s4_c.sql" > "$TMP/s4_c.out" 2>&1
check "konkurensi: checkout berikutnya memakai harga baru (20000 + 5000)" "$(q "select total from public.orders where idempotency_key='conc-price-after'")" 25000.00
cleanup

# --- S5: dua checkout kunci berbeda, customer sama, bersamaan (diserialkan) ---
checkout_sql $CUST_A $NASI 1 conc-multi-1 1 > "$TMP/s5_a.sql"
checkout_sql $CUST_A $TEH 1 conc-multi-2 0 > "$TMP/s5_b.sql"
( "${P[@]}" -f "$TMP/s5_a.sql" > "$TMP/s5_a.out" 2>&1 ) &
sleep 0.3
( "${P[@]}" -f "$TMP/s5_b.sql" > "$TMP/s5_b.out" 2>&1 ) &
wait
check "konkurensi: dua checkout berbeda kunci keduanya sukses (2 order terpisah)" "$(q "select count(*) from public.orders where idempotency_key in ('conc-multi-1','conc-multi-2')")" 2
check "konkurensi: tiap order punya tepat 1 item" "$(q "select count(*) from public.order_items i join public.orders o on o.id=i.order_id where o.idempotency_key like 'conc-multi-%'")" 2
cleanup
