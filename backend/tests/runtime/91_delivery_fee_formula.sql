-- Rumus ongkir per jarak + batas radius 5 km (migrasi 20261112000001, keputusan pemilik 12 Nov 2026):
-- <=1000 m flat Rp2000; di atasnya 2000 + ceil((m-1000)/100)*200 (contoh: 2350 m -> 4800).
-- stores.delivery_fee dipertahankan tapi tidak lagi dipakai/diwajibkan saat checkout.
-- Semua dalam satu transaksi yang di-rollback.
\set ON_ERROR_STOP on
begin;

-- A. Helper delivery_fee_for_distance: batas-batas eksak.
do $$
begin
  perform t.ok('fee: 0 m -> 2000', public.delivery_fee_for_distance(0) = 2000);
  perform t.ok('fee: 500 m -> 2000', public.delivery_fee_for_distance(500) = 2000);
  perform t.ok('fee: 1000 m -> 2000', public.delivery_fee_for_distance(1000) = 2000);
  perform t.ok('fee: 1001 m -> 2200', public.delivery_fee_for_distance(1001) = 2200);
  perform t.ok('fee: 1100 m -> 2200', public.delivery_fee_for_distance(1100) = 2200);
  perform t.ok('fee: 2350 m -> 4800 (contoh pemilik)', public.delivery_fee_for_distance(2350) = 4800);
  perform t.ok('fee: 5000 m -> 10000', public.delivery_fee_for_distance(5000) = 10000);
  perform t.ok('fee: 100000 m -> 200000', public.delivery_fee_for_distance(100000) = 200000);
  perform t.expect_err('fee: null ditolak', 'select public.delivery_fee_for_distance(null)', 'invalid_distance');
  perform t.expect_err('fee: negatif ditolak', 'select public.delivery_fee_for_distance(-1)', 'invalid_distance');
end $$;

-- B. Batas radius: constraint ada dan ditegakkan.
do $$
declare
  adm constant uuid := '40000000-0000-0000-0000-000000000001';
  storeA constant uuid := '50000000-0000-0000-0000-00000000000a';
begin
  perform t.ok('radius: constraint stores_service_radius_max_5km ada dan tervalidasi',
    exists (select 1 from pg_constraint where conrelid = 'public.stores'::regclass
            and conname = 'stores_service_radius_max_5km' and convalidated));
  perform t.expect_err('radius: UPDATE service_radius_km = 5.01 ditolak constraint',
    $q$update public.stores set service_radius_km = 5.01 where id = '50000000-0000-0000-0000-00000000000a'$q$,
    'stores_service_radius_max_5km');
  update public.stores set service_radius_km = 5 where id = storeA;
  perform t.ok('radius: service_radius_km = 5 diterima (batas atas)',
    (select service_radius_km from public.stores where id = storeA) = 5);
  perform t.login(adm);
  perform t.expect_err('radius: admin_set_store_delivery_config radius 6 ditolak constraint',
    format($q$select public.admin_set_store_delivery_config(%L, 8000, 6)$q$, storeA),
    'stores_service_radius_max_5km');
  perform t.logout();
  perform t.ok('radius: konfigurasi toko A tidak berubah setelah penolakan',
    (select delivery_fee = 5000 and service_radius_km = 5 from public.stores where id = storeA));
end $$;

-- C. create_order: ongkir mengikuti rumus jarak, bukan fee toko.
do $$
declare
  cA constant uuid := '10000000-0000-0000-0000-00000000000a';
  storeA constant uuid := '50000000-0000-0000-0000-00000000000a';
  items constant jsonb := '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":1}]';
  o uuid; r record; v_lat numeric; v_lon numeric; v_fee numeric;
begin
  -- Koordinat default (-6.21, 106.81) ~1568 m dari toko A: ongkir 3200, bukan fee toko 5000.
  o := t.make_order(cA, storeA, items);
  perform t.ok('fee: checkout jarak ~1568 m ongkir 3200 (bukan fee toko 5000)',
    (select delivery_fee from public.orders where id = o) = 3200
    and (select total from public.orders where id = o) = 10000 + 3200);

  -- Jarak dekat (-6.2010, 106.8010) ~157 m: ongkir flat 2000.
  perform t.login(cA);
  select * into r from public.create_order(storeA, items, 'Jl. Dekat', -6.2010, 106.8010, null, 'cod', 'fee-dekat-0001');
  perform t.logout();
  perform t.ok('fee: jarak ~157 m ongkir flat 2000', r.delivery_fee = 2000 and r.total = 10000 + 2000);

  -- Jarak jauh ke utara (~2350 m): ongkir = rumus jarak sebenarnya (self-consistent dengan helper).
  perform t.login(cA);
  select * into r from public.create_order(storeA, items, 'Jl. Utara', -6.178867, 106.8, null, 'cod', 'fee-utara-2350');
  perform t.logout();
  select delivery_latitude, delivery_longitude, delivery_fee into v_lat, v_lon, v_fee
    from public.orders where id = r.order_id;
  perform t.ok('fee: ongkir checkout = rumus jarak sebenarnya',
    v_fee = public.delivery_fee_for_distance(round(public.haversine_km(-6.2, 106.8, v_lat, v_lon) * 1000)::integer));

  -- Di luar radius tetap ditolak.
  perform t.login(cA);
  perform t.try_order('fee: di luar radius tetap ditolak', 'outside_store_service_radius', storeA, items, '-6.5', '107.2');
  perform t.logout();
end $$;

-- D. Toko tanpa delivery_fee (null) tapi radius+koordinat terisi tetap bisa checkout.
do $$
declare
  cA constant uuid := '10000000-0000-0000-0000-00000000000a';
  o uuid;
begin
  insert into public.stores (id, owner_id, name, address, latitude, longitude, is_active, delivery_fee, service_radius_km)
  values ('50000000-0000-0000-0000-0000000000e1', '20000000-0000-0000-0000-00000000000a',
          'Warung Tanpa Fee', 'Jl. E 5', -6.200000, 106.800000, true, null, 5);
  insert into public.products (id, store_id, name, price)
  values ('60000000-0000-0000-0000-0000000000e1', '50000000-0000-0000-0000-0000000000e1', 'Nasi Tanpa Fee', 8000);
  o := t.make_order(cA, '50000000-0000-0000-0000-0000000000e1',
    '[{"product_id":"60000000-0000-0000-0000-0000000000e1","quantity":1}]');
  perform t.ok('fee: toko tanpa delivery_fee tetap bisa checkout (hanya radius+koordinat wajib)',
    (select delivery_fee from public.orders where id = o) = 3200
    and (select total from public.orders where id = o) = 8000 + 3200);
end $$;

rollback;
