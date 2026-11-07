-- Negatif checkout: tampering harga, item, koordinat/radius, toko, idempotensi, rollback.
\set ON_ERROR_STOP on
begin;

do $$
declare
  sA constant uuid := '50000000-0000-0000-0000-00000000000a';
  pA1 constant text := '60000000-0000-0000-0000-0000000000a1';
  pA2 constant text := '60000000-0000-0000-0000-0000000000a2';
  r record; v_id uuid; v_id2 uuid; n int; big jsonb;
begin
  perform t.login('10000000-0000-0000-0000-00000000000a');

  -- Peran
  perform t.login('20000000-0000-0000-0000-00000000000a');
  perform t.try_order('role: seller tidak bisa checkout', 'customer_role_required', sA, jsonb_build_array(jsonb_build_object('product_id', pA1, 'quantity', 1)));
  perform t.login('30000000-0000-0000-0000-00000000000a');
  perform t.try_order('role: driver tidak bisa checkout', 'customer_role_required', sA, jsonb_build_array(jsonb_build_object('product_id', pA1, 'quantity', 1)));
  perform t.login('40000000-0000-0000-0000-000000000001');
  perform t.try_order('role: admin tidak bisa checkout', 'customer_role_required', sA, jsonb_build_array(jsonb_build_object('product_id', pA1, 'quantity', 1)));
  perform t.login('10000000-0000-0000-0000-00000000000a');

  -- Item
  perform t.try_order('item: produk toko lain ditolak', 'product_unavailable_or_wrong_store', sA,
    '[{"product_id":"60000000-0000-0000-0000-0000000000b1","quantity":1}]');
  perform t.try_order('item: campuran produk toko A dan B ditolak', 'product_unavailable_or_wrong_store', sA,
    jsonb_build_array(jsonb_build_object('product_id', pA1, 'quantity', 1), jsonb_build_object('product_id', '60000000-0000-0000-0000-0000000000b1', 'quantity', 1)));
  perform t.try_order('item: produk tidak tersedia ditolak', 'product_unavailable_or_wrong_store', sA,
    '[{"product_id":"60000000-0000-0000-0000-0000000000a3","quantity":1}]');
  perform t.try_order('item: produk tak ada ditolak', 'product_unavailable_or_wrong_store', sA,
    '[{"product_id":"99999999-0000-0000-0000-000000000000","quantity":1}]');
  perform t.try_order('item: duplikat produk ditolak', 'duplicate_product_in_items', sA,
    jsonb_build_array(jsonb_build_object('product_id', pA1, 'quantity', 1), jsonb_build_object('product_id', pA1, 'quantity', 2)));
  perform t.try_order('item: quantity 0 ditolak', 'invalid_order_item', sA, jsonb_build_array(jsonb_build_object('product_id', pA1, 'quantity', 0)));
  perform t.try_order('item: quantity 100 ditolak', 'invalid_order_item', sA, jsonb_build_array(jsonb_build_object('product_id', pA1, 'quantity', 100)));
  perform t.try_order('item: quantity negatif ditolak', 'invalid_order_item', sA, jsonb_build_array(jsonb_build_object('product_id', pA1, 'quantity', -1)));
  perform t.try_order('item: quantity non-angka ditolak', 'invalid_order_item', sA, jsonb_build_array(jsonb_build_object('product_id', pA1, 'quantity', 'abc')));
  perform t.try_order('item: product_id bukan uuid ditolak', 'invalid_order_item', sA, '[{"product_id":"bukan-uuid","quantity":1}]');
  perform t.try_order('item: product_id hilang ditolak', 'invalid_order_item', sA, '[{"quantity":1}]');
  perform t.try_order('item: array kosong ditolak', 'item_count_out_of_range', sA, '[]');
  select jsonb_agg(jsonb_build_object('product_id', gen_random_uuid(), 'quantity', 1)) into big from generate_series(1, 51);
  perform t.try_order('item: 51 item ditolak', 'item_count_out_of_range', sA, big);
  perform t.try_order('item: bukan array ditolak', 'items_must_be_array', sA, '{"product_id":"x"}');
  perform t.expect_err('item: items null ditolak',
    $q$select * from public.create_order('50000000-0000-0000-0000-00000000000a', null, 'Jl. X', -6.21, 106.81)$q$, 'items_must_be_array');

  -- Toko
  perform t.try_order('toko: nonaktif ditolak', 'store_not_available', '50000000-0000-0000-0000-00000000000c',
    '[{"product_id":"60000000-0000-0000-0000-0000000000c1","quantity":1}]');
  perform t.try_order('toko: tak ada ditolak', 'store_not_available', gen_random_uuid(), '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":1}]');
  perform t.try_order('toko: belum dikonfigurasi (fee/radius null) ditolak', 'store_delivery_not_configured', '50000000-0000-0000-0000-00000000000d',
    '[{"product_id":"60000000-0000-0000-0000-0000000000d1","quantity":1}]');

  -- Koordinat dan radius
  perform t.try_order('koordinat: di luar radius ditolak', 'outside_store_service_radius', sA,
    '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":1}]', '-6.3', '106.9');
  perform t.try_order('koordinat: radius toko B (3 km) ditolak untuk titik 4 km', 'outside_store_service_radius', '50000000-0000-0000-0000-00000000000b',
    '[{"product_id":"60000000-0000-0000-0000-0000000000b1","quantity":1}]', '-6.255', '106.82');
  perform t.try_order('koordinat: NaN lat ditolak', 'valid_delivery_coordinates_required', sA,
    '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":1}]', '''NaN''', '106.81');
  perform t.try_order('koordinat: NaN lon ditolak', 'valid_delivery_coordinates_required', sA,
    '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":1}]', '-6.21', '''NaN''');
  perform t.try_order('koordinat: Infinity ditolak', 'valid_delivery_coordinates_required', sA,
    '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":1}]', '''Infinity''', '106.81');
  perform t.try_order('koordinat: lat 91 ditolak', 'valid_delivery_coordinates_required', sA,
    '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":1}]', '91', '106.81');
  perform t.try_order('koordinat: lon -181 ditolak', 'valid_delivery_coordinates_required', sA,
    '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":1}]', '-6.21', '-181');
  perform t.try_order('koordinat: null ditolak', 'valid_delivery_coordinates_required', sA,
    '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":1}]', 'null', 'null');

  -- Alamat, catatan, pembayaran, kunci idempotensi
  perform t.expect_err('alamat: kosong ditolak',
    $q$select * from public.create_order('50000000-0000-0000-0000-00000000000a', '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":1}]', '   ', -6.21, 106.81)$q$, 'delivery_address_required');
  perform t.expect_err('catatan: > 1000 karakter ditolak',
    format($q$select * from public.create_order('50000000-0000-0000-0000-00000000000a', '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":1}]', 'Jl. X', -6.21, 106.81, %L)$q$, repeat('x', 1001)), 'delivery_note_too_long');
  perform t.try_order('pembayaran: manual_transfer ditolak (fail closed)', 'manual_transfer_not_configured', sA,
    '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":1}]', '-6.21', '106.81', 'manual_transfer');
  perform t.try_order('idempotensi: kunci terlalu pendek ditolak', 'invalid_idempotency_key', sA,
    '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":1}]', '-6.21', '106.81', 'cod', 'abc');
  perform t.try_order('idempotensi: kunci berisi karakter terlarang ditolak', 'invalid_idempotency_key', sA,
    '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":1}]', '-6.21', '106.81', 'cod', 'kunci tidak valid!');

  -- Manual transfer tetap ditolak walau flag kebijakan dinyalakan
  perform t.logout();
  perform public.provision_set_policy('manual_transfer_enabled', 'true');
  perform t.login('10000000-0000-0000-0000-00000000000a');
  perform t.try_order('pembayaran: manual_transfer tetap ditolak walau manual_transfer_enabled=true', 'manual_transfer_not_configured', sA,
    '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":1}]', '-6.21', '106.81', 'manual_transfer');
  perform t.logout();

  -- Tidak ada order tersisa dari semua penolakan di atas
  select count(*) into n from public.orders where customer_id = '10000000-0000-0000-0000-00000000000a' and idempotency_key is distinct from 'e2e-cod-0001';
  perform t.ok('rollback: seluruh checkout gagal tidak meninggalkan order', n = 0);
  perform t.ok('rollback: tidak ada item yatim (order_items tanpa order)',
    not exists (select 1 from public.order_items i where not exists (select 1 from public.orders o where o.id = i.order_id)));
  perform t.ok('rollback: tidak ada riwayat yatim', not exists (select 1 from public.order_status_history h where not exists (select 1 from public.orders o where o.id = h.order_id)));

  -- Tampering harga di payload: field harga diabaikan, harga dari DB
  perform t.login('10000000-0000-0000-0000-00000000000a');
  select * into r from public.create_order(sA,
    jsonb_build_array(jsonb_build_object('product_id', pA1, 'quantity', 1, 'price', 1, 'unit_price', 1, 'line_total', 1, 'name', 'gratis')),
    'Jl. X', -6.21, 106.81, null, 'cod', 'tamper-0001');
  perform t.ok('tampering: harga/nama di payload diabaikan (subtotal 10000, total 15000)', r.subtotal = 10000 and r.total = 15000);
  perform t.ok('tampering: snapshot memakai nama & harga DB',
    exists (select 1 from public.order_items where order_id = r.order_id and product_name_snapshot = 'Nasi Goreng A' and unit_price_snapshot = 10000 and line_total = 10000));
  perform t.logout();

  -- Idempotensi
  perform t.login('10000000-0000-0000-0000-00000000000a');
  select order_id into v_id from public.create_order(sA, jsonb_build_array(jsonb_build_object('product_id', pA2, 'quantity', 2)), 'Jl. X', -6.21, 106.81, null, 'cod', 'idem-test-01');
  select order_id into v_id2 from public.create_order(sA, jsonb_build_array(jsonb_build_object('product_id', pA2, 'quantity', 2)), 'Jl. X', -6.21, 106.81, null, 'cod', 'idem-test-01');
  perform t.ok('idempotensi: kunci sama mengembalikan order yang sama', v_id = v_id2);
  perform t.logout();
  perform t.ok('idempotensi: hanya satu order, satu set item, satu riwayat dibuat',
    (select count(*) from public.orders where idempotency_key = 'idem-test-01') = 1
    and (select count(*) from public.order_items where order_id = v_id) = 1
    and (select count(*) from public.order_status_history where order_id = v_id) = 1);
  perform t.login('10000000-0000-0000-0000-00000000000a');
  perform t.expect_err('idempotensi: kunci sama untuk toko berbeda ditolak (conflict)',
    t.co_sql('50000000-0000-0000-0000-00000000000b', '[{"product_id":"60000000-0000-0000-0000-0000000000b1","quantity":1}]', '-6.21', '106.81', 'cod', 'idem-test-01'), 'idempotency_key_conflict');
  perform t.logout();
end $$;

-- Replay dengan payload berubah ditolak; replay identik mengabaikan status toko saat ini.
do $$
declare
  sA constant uuid := '50000000-0000-0000-0000-00000000000a';
  pA1 constant text := '60000000-0000-0000-0000-0000000000a1';
  pA2 constant text := '60000000-0000-0000-0000-0000000000a2';
  v_id uuid; v_id2 uuid; v_p1 uuid; v_p2 uuid; v_it jsonb := jsonb_build_array(jsonb_build_object('product_id', pA2, 'quantity', 2));
begin
  perform t.login('10000000-0000-0000-0000-00000000000a');
  select order_id into v_id from public.create_order(sA, v_it, 'Jl. Payload', -6.21, 106.81, 'catatan', 'cod', 'payload-key-01');
  perform t.expect_err('idempotensi: quantity berbeda ditolak',
    format('select * from public.create_order(%L, %L::jsonb, ''Jl. Payload'', -6.21, 106.81, ''catatan'', ''cod'', ''payload-key-01'')', sA, jsonb_build_array(jsonb_build_object('product_id', pA2, 'quantity', 3))), 'idempotency_key_conflict');
  perform t.expect_err('idempotensi: produk berbeda ditolak',
    format('select * from public.create_order(%L, %L::jsonb, ''Jl. Payload'', -6.21, 106.81, ''catatan'', ''cod'', ''payload-key-01'')', sA, jsonb_build_array(jsonb_build_object('product_id', pA1, 'quantity', 2))), 'idempotency_key_conflict');
  perform t.expect_err('idempotensi: item tambahan ditolak',
    format('select * from public.create_order(%L, %L::jsonb, ''Jl. Payload'', -6.21, 106.81, ''catatan'', ''cod'', ''payload-key-01'')', sA, v_it || jsonb_build_array(jsonb_build_object('product_id', pA1, 'quantity', 1))), 'idempotency_key_conflict');
  perform t.expect_err('idempotensi: alamat berbeda ditolak',
    format('select * from public.create_order(%L, %L::jsonb, ''Jl. Lain'', -6.21, 106.81, ''catatan'', ''cod'', ''payload-key-01'')', sA, v_it), 'idempotency_key_conflict');
  perform t.expect_err('idempotensi: koordinat berbeda ditolak',
    format('select * from public.create_order(%L, %L::jsonb, ''Jl. Payload'', -6.211, 106.81, ''catatan'', ''cod'', ''payload-key-01'')', sA, v_it), 'idempotency_key_conflict');
  perform t.expect_err('idempotensi: catatan berbeda ditolak',
    format('select * from public.create_order(%L, %L::jsonb, ''Jl. Payload'', -6.21, 106.81, ''lain'', ''cod'', ''payload-key-01'')', sA, v_it), 'idempotency_key_conflict');
  perform t.expect_err('idempotensi: catatan dihapus ditolak',
    format('select * from public.create_order(%L, %L::jsonb, ''Jl. Payload'', -6.21, 106.81, null, ''cod'', ''payload-key-01'')', sA, v_it), 'idempotency_key_conflict');
  perform t.expect_err('idempotensi: items rusak ditolak sebagai conflict',
    format('select * from public.create_order(%L, ''[{"product_id":"bukan-uuid","quantity":1}]''::jsonb, ''Jl. Payload'', -6.21, 106.81, ''catatan'', ''cod'', ''payload-key-01'')', sA), 'idempotency_key_conflict');
  select order_id into v_id2 from public.create_order(sA, v_it, '  Jl. Payload  ', -6.21, 106.81, 'catatan', 'cod', 'payload-key-01');
  perform t.ok('idempotensi: payload identik (spasi tepi diabaikan) mengembalikan order yang sama', v_id = v_id2);
  -- Koordinat dengan presisi >6 desimal: pembulatan sekali, replay tetap cocok.
  select order_id into v_p1 from public.create_order(sA, v_it, 'Jl. Presisi', -6.2100004, 106.8100004, null, 'cod', 'precision-key-01');
  select order_id into v_p2 from public.create_order(sA, v_it, 'Jl. Presisi', -6.2100004, 106.8100004, null, 'cod', 'precision-key-01');
  perform t.ok('idempotensi: koordinat 7 desimal, replay mengembalikan order yang sama', v_p1 = v_p2);
  perform t.ok('koordinat 7 desimal tersimpan dibulatkan ke 6 desimal',
    exists (select 1 from public.orders where id = v_p1 and delivery_latitude = -6.210000 and delivery_longitude = 106.810000));
  select order_id into v_p2 from public.create_order(sA, v_it, 'Jl. Presisi', -6.21, 106.81, null, 'cod', 'precision-key-01');
  perform t.ok('idempotensi: replay dengan nilai terbulat setara mengembalikan order yang sama', v_p1 = v_p2);
  perform t.logout();
  -- Toko dinonaktifkan setelah order: replay identik tetap mengembalikan order lama.
  perform t.login('40000000-0000-0000-0000-000000000001');
  perform public.admin_set_store_active(sA, false);
  perform t.login('10000000-0000-0000-0000-00000000000a');
  select order_id into v_id2 from public.create_order(sA, v_it, 'Jl. Payload', -6.21, 106.81, 'catatan', 'cod', 'payload-key-01');
  perform t.ok('idempotensi: replay mengabaikan toko yang kini nonaktif', v_id = v_id2);
  perform t.try_order('idempotensi: kunci baru ke toko nonaktif tetap ditolak', 'store_not_available', sA, v_it, '-6.21', '106.81', 'cod', 'payload-key-02');
  -- Riwayat tetap memuat order dari toko nonaktif.
  perform t.ok('riwayat: customer tetap melihat order toko nonaktif',
    exists (select 1 from public.list_my_orders() where order_id = v_id and store_name is null));
  perform t.logout();
  perform t.login('40000000-0000-0000-0000-000000000001');
  perform t.ok('riwayat: admin melihat order toko nonaktif dengan nama toko',
    exists (select 1 from public.list_my_orders() where order_id = v_id and store_name is not null));
  perform public.admin_set_store_active(sA, true);
  perform t.logout();
end $$;

-- Kunci idempotensi dibatasi per customer; retry setelah harga berubah tidak membuat order baru.
do $$
declare v_a uuid; v_b uuid; v_c uuid; v_d uuid;
begin
  perform t.login('10000000-0000-0000-0000-00000000000a');
  select order_id into v_a from public.create_order('50000000-0000-0000-0000-00000000000a', '[{"product_id":"60000000-0000-0000-0000-0000000000a2","quantity":1}]', 'Jl. X', -6.21, 106.81, null, 'cod', 'shared-key-01');
  perform t.login('10000000-0000-0000-0000-00000000000b');
  select order_id into v_b from public.create_order('50000000-0000-0000-0000-00000000000a', '[{"product_id":"60000000-0000-0000-0000-0000000000a2","quantity":1}]', 'Jl. X', -6.21, 106.81, null, 'cod', 'shared-key-01');
  perform t.ok('idempotensi: kunci sama dari customer berbeda menghasilkan order berbeda', v_a <> v_b);
  perform t.logout();
  update public.products set price = 5000 where id = '60000000-0000-0000-0000-0000000000a2';
  perform t.login('10000000-0000-0000-0000-00000000000a');
  select order_id into v_c from public.create_order('50000000-0000-0000-0000-00000000000a', '[{"product_id":"60000000-0000-0000-0000-0000000000a2","quantity":1}]', 'Jl. X', -6.21, 106.81, null, 'cod', 'shared-key-01');
  perform t.ok('idempotensi: retry setelah harga berubah mengembalikan order lama (harga lama)',
    v_c = v_a and (select total from public.orders where id = v_c) = 9000);
  -- Tanpa kunci, dua checkout identik membuat dua order (perilaku terdokumentasi).
  select order_id into v_c from public.create_order('50000000-0000-0000-0000-00000000000a', '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":1}]', 'Jl. X', -6.21, 106.81);
  select order_id into v_d from public.create_order('50000000-0000-0000-0000-00000000000a', '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":1}]', 'Jl. X', -6.21, 106.81);
  perform t.ok('tanpa kunci idempotensi: dua checkout identik menjadi dua order (klien wajib kirim kunci)', v_c <> v_d);
  perform t.logout();
end $$;

-- Rollback atomik: kegagalan di tengah create_order (insert riwayat) tidak menyisakan order/item.
do $$
declare n_o int; n_i int;
begin
  create function public.tmp_force_fail() returns trigger language plpgsql as $f$ begin raise exception 'forced_failure'; end $f$;
  create trigger tmp_force_fail before insert on public.order_status_history for each row execute function public.tmp_force_fail();
  select count(*) into n_o from public.orders where customer_id = '10000000-0000-0000-0000-00000000000b';
  select count(*) into n_i from public.order_items;
  perform t.login('10000000-0000-0000-0000-00000000000b');
  perform t.expect_err('rollback: kegagalan di akhir create_order diteruskan sebagai error',
    t.co_sql('50000000-0000-0000-0000-00000000000a', '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":3}]', '-6.21', '106.81', 'cod', 'rollback-key-1'), 'forced_failure');
  perform t.logout();
  perform t.ok('rollback: order dan item dari create_order yang gagal tidak tersisa',
    (select count(*) from public.orders where customer_id = '10000000-0000-0000-0000-00000000000b') = n_o
    and (select count(*) from public.order_items) = n_i
    and not exists (select 1 from public.orders where idempotency_key = 'rollback-key-1'));
  drop trigger tmp_force_fail on public.order_status_history;
end $$;

rollback;
