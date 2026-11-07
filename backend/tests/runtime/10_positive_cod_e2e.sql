-- E2E COD positif: customer -> seller accepted/preparing/ready -> admin assign -> driver picked_up/delivered -> completed.
-- Tiap langkah memakai transaksi sendiri (DO terpisah) agar created_at riwayat berurutan.
-- Order E2E (kunci e2e-cod-0001) tetap ada untuk tes isolasi berikutnya.
\set ON_ERROR_STOP on

-- Langkah 1: checkout. Payload membawa field harga palsu yang harus diabaikan.
do $$
declare r record; v_n int;
begin
  perform t.login('10000000-0000-0000-0000-00000000000a');
  select * into r from public.create_order(
    '50000000-0000-0000-0000-00000000000a',
    '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":2,"price":1,"unit_price":1,"line_total":1},
      {"product_id":"60000000-0000-0000-0000-0000000000a2","quantity":3}]'::jsonb,
    'Jl. Tujuan 1', -6.21, 106.81, 'tanpa sambal', 'cod', 'e2e-cod-0001');
  perform t.logout();
  perform t.ok('e2e: subtotal 2x10000 + 3x4000 = 32000 (field harga payload diabaikan)', r.subtotal = 32000);
  perform t.ok('e2e: ongkir dari toko = 5000', r.delivery_fee = 5000);
  perform t.ok('e2e: total = subtotal + ongkir = 37000', r.total = 37000);
  perform t.ok('e2e: COD, payment_status unpaid, status pending_seller',
    r.payment_method = 'cod' and r.payment_status = 'unpaid' and r.order_status = 'pending_seller');
  select count(*) into v_n from public.order_items oi where oi.order_id = r.order_id;
  perform t.ok('e2e: 2 baris item tersimpan', v_n = 2);
  perform t.ok('e2e: snapshot item (nama, harga satuan, total baris)',
    exists (select 1 from public.order_items where order_id = r.order_id and product_name_snapshot = 'Nasi Goreng A'
            and unit_price_snapshot = 10000 and quantity = 2 and line_total = 20000)
    and exists (select 1 from public.order_items where order_id = r.order_id and product_name_snapshot = 'Teh Manis A'
            and unit_price_snapshot = 4000 and quantity = 3 and line_total = 12000));
end $$;

-- Langkah 2: seller A menerima, menyiapkan.
do $$
declare v_o uuid := (select id from public.orders where idempotency_key = 'e2e-cod-0001');
begin
  perform t.status_as('20000000-0000-0000-0000-00000000000a', v_o, 'accepted');
  perform t.ok('e2e: seller A pending_seller -> accepted',
    (select order_status from public.orders where id = v_o) = 'accepted');
end $$;
do $$
declare v_o uuid := (select id from public.orders where idempotency_key = 'e2e-cod-0001');
begin
  perform t.status_as('20000000-0000-0000-0000-00000000000a', v_o, 'preparing');
  perform t.ok('e2e: seller A accepted -> preparing', (select order_status from public.orders where id = v_o) = 'preparing');
end $$;

-- Langkah 3: admin menugaskan driver A (saat preparing).
do $$
declare v_o uuid := (select id from public.orders where idempotency_key = 'e2e-cod-0001'); v_d uuid;
begin
  perform t.login('40000000-0000-0000-0000-000000000001');
  v_d := public.assign_order_driver(v_o, '30000000-0000-0000-0000-00000000000a');
  perform t.logout();
  perform t.ok('e2e: admin menugaskan driver A', v_d = '30000000-0000-0000-0000-00000000000a'
    and (select driver_id from public.orders where id = v_o) = '30000000-0000-0000-0000-00000000000a');
  perform t.ok('e2e: penugasan tercatat di audit log admin',
    exists (select 1 from public.admin_audit_log where action = 'assign_order_driver' and target_id = v_o::text
            and actor_id = '40000000-0000-0000-0000-000000000001'));
end $$;

do $$
declare v_o uuid := (select id from public.orders where idempotency_key = 'e2e-cod-0001');
begin
  perform t.status_as('20000000-0000-0000-0000-00000000000a', v_o, 'ready_for_pickup');
  perform t.ok('e2e: seller A preparing -> ready_for_pickup', (select order_status from public.orders where id = v_o) = 'ready_for_pickup');
end $$;

-- Langkah 4: driver A mengambil dan mengantar.
do $$
declare v_o uuid := (select id from public.orders where idempotency_key = 'e2e-cod-0001');
begin
  perform t.status_as('30000000-0000-0000-0000-00000000000a', v_o, 'picked_up');
  perform t.ok('e2e: driver A ready_for_pickup -> picked_up', (select order_status from public.orders where id = v_o) = 'picked_up');
end $$;
do $$
declare v_o uuid := (select id from public.orders where idempotency_key = 'e2e-cod-0001');
begin
  perform t.status_as('30000000-0000-0000-0000-00000000000a', v_o, 'delivered');
  perform t.ok('e2e: driver A picked_up -> delivered', (select order_status from public.orders where id = v_o) = 'delivered');
  -- Kondisi pembayaran: delivered TIDAK menandai lunas. Pelunasan COD butuh kebijakan operator
  -- (cod_collection_recording_enabled + cod_collection_actor) yang belum dikonfigurasi default.
  perform t.ok('e2e: setelah delivered, payment_status tetap unpaid',
    (select payment_status from public.orders where id = v_o) = 'unpaid');
end $$;

-- Langkah 5: completion oleh aktor yang diizinkan (default kebijakan: customer).
do $$
declare v_o uuid := (select id from public.orders where idempotency_key = 'e2e-cod-0001');
begin
  perform t.status_as('10000000-0000-0000-0000-00000000000a', v_o, 'completed');
  perform t.ok('e2e: customer delivered -> completed', (select order_status from public.orders where id = v_o) = 'completed');
  perform t.ok('e2e: setelah completed, payment_status tetap unpaid (tidak otomatis lunas)',
    (select payment_status from public.orders where id = v_o) = 'unpaid');
  raise notice 'CATATAN: pembayaran COD order e2e masih unpaid/pending karena kebijakan penerimaan COD (cod_collection_*) belum dikonfigurasi; delivered/completed tidak melunasi.';
end $$;

-- Riwayat lengkap beserta aktor (8 baris: create, 3 seller, assign admin, 2 driver, complete).
do $$
declare v_o uuid := (select id from public.orders where idempotency_key = 'e2e-cod-0001'); v_seq text;
begin
  select string_agg(coalesce(old_status::text, 'null') || '>' || new_status::text || '@' || left(changed_by::text, 2), ' | ' order by created_at)
    into v_seq from public.order_status_history where order_id = v_o;
  perform t.ok('e2e: riwayat status berurutan dengan aktor benar (' || v_seq || ')',
    v_seq = 'null>pending_seller@10 | pending_seller>accepted@20 | accepted>preparing@20 | preparing>preparing@40 | '
         || 'preparing>ready_for_pickup@20 | ready_for_pickup>picked_up@30 | picked_up>delivered@30 | delivered>completed@10');
end $$;

-- Snapshot tidak berubah saat harga/nama produk berubah setelah order.
do $$
declare v_o uuid := (select id from public.orders where idempotency_key = 'e2e-cod-0001');
begin
  update public.products set price = 99999, name = 'Nasi Goreng Mahal' where id = '60000000-0000-0000-0000-0000000000a1';
  perform t.ok('e2e: harga produk berubah tidak mengubah snapshot item',
    exists (select 1 from public.order_items where order_id = v_o and product_name_snapshot = 'Nasi Goreng A'
            and unit_price_snapshot = 10000 and line_total = 20000));
  perform t.ok('e2e: harga produk berubah tidak mengubah subtotal/total order',
    (select subtotal from public.orders where id = v_o) = 32000 and (select total from public.orders where id = v_o) = 37000);
  update public.products set price = 10000, name = 'Nasi Goreng A' where id = '60000000-0000-0000-0000-0000000000a1';
end $$;

-- Seluruh pembayaran: tidak ada jalur delivered/completed yang melunasi.
do $$
begin
  perform t.ok('e2e: tidak ada order berstatus delivered/completed dengan payment verified',
    not exists (select 1 from public.orders where order_status in ('delivered', 'completed') and payment_status = 'verified'));
end $$;
