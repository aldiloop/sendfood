-- Negatif: anon, eskalasi role, isolasi antar akun, penulisan langsung ke order.
\set ON_ERROR_STOP on
begin;

-- ===== Anon =====
do $$
declare n int;
begin
  perform t.login(null, 'anon');
  perform t.expect_err('anon: tidak bisa membaca orders', 'select count(*) from public.orders', 'permission denied');
  perform t.expect_err('anon: tidak bisa membaca order_items', 'select count(*) from public.order_items', 'permission denied');
  perform t.expect_err('anon: tidak bisa membaca order_status_history', 'select count(*) from public.order_status_history', 'permission denied');
  perform t.expect_err('anon: tidak bisa membaca profiles', 'select count(*) from public.profiles', 'permission denied');
  perform t.expect_err('anon: tidak bisa membaca customer_addresses', 'select count(*) from public.customer_addresses', 'permission denied');
  perform t.expect_err('anon: tidak bisa membaca ops_policy', 'select count(*) from public.ops_policy', 'permission denied');
  perform t.expect_err('anon: tidak bisa membaca admin_audit_log', 'select count(*) from public.admin_audit_log', 'permission denied');
  perform t.expect_err('anon: create_order ditolak',
    t.co_sql('50000000-0000-0000-0000-00000000000a', '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":1}]'), 'permission denied');
  perform t.expect_err('anon: change_order_status ditolak',
    $q$select public.change_order_status(gen_random_uuid(), 'accepted', null)$q$, 'permission denied');
  perform t.expect_err('anon: assign_order_driver ditolak',
    $q$select public.assign_order_driver(gen_random_uuid(), gen_random_uuid())$q$, 'permission denied');
  perform t.expect_err('anon: list_my_orders ditolak', $q$select * from public.list_my_orders()$q$, 'permission denied');
  perform t.expect_err('anon: record_cod_collection ditolak', $q$select public.record_cod_collection(gen_random_uuid())$q$, 'permission denied');
  perform t.expect_err('anon: admin_get_policies ditolak', $q$select * from public.admin_get_policies()$q$, 'permission denied');
  perform t.expect_err('anon: admin_set_store_active ditolak',
    $q$select public.admin_set_store_active('50000000-0000-0000-0000-00000000000a', false)$q$, 'permission denied');
  perform t.expect_err('anon: provision_set_user_role ditolak',
    $q$select public.provision_set_user_role('10000000-0000-0000-0000-00000000000a', 'admin')$q$, 'permission denied');
  perform t.expect_err('anon: provision_set_policy ditolak',
    $q$select public.provision_set_policy('cancellation_enabled', 'true')$q$, 'permission denied');
  perform t.expect_err('anon: tidak bisa insert stores', $q$insert into public.stores (owner_id, name, address) values (gen_random_uuid(), 'x', 'y')$q$, 'permission denied');
  select count(*) into n from public.stores;
  perform t.ok('anon: hanya melihat toko aktif (3 dari 4)', n = 3);
  select count(*) into n from public.products;
  perform t.ok('anon: hanya melihat produk tersedia di toko aktif (4 dari 6)', n = 4);
  perform t.logout();
end $$;

-- Authenticated tanpa klaim sub (token tanpa user)
do $$
begin
  perform t.login(null, 'authenticated');
  perform t.expect_err('authenticated tanpa sub: create_order -> authentication_required',
    t.co_sql('50000000-0000-0000-0000-00000000000a', '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":1}]'), 'authentication_required');
  perform t.expect_err('authenticated tanpa sub: change_order_status -> authentication_required',
    $q$select public.change_order_status(gen_random_uuid(), 'accepted', null)$q$, 'authentication_required');
  perform t.logout();
end $$;

-- ===== Eskalasi role =====
do $$
declare v_role text; v_n int;
begin
  perform t.login('10000000-0000-0000-0000-00000000000a');
  perform t.expect_err('eskalasi: customer update profiles.role ditolak',
    $q$update public.profiles set role = 'admin' where id = auth.uid()$q$, 'permission denied');
  perform t.expect_err('eskalasi: customer update profiles.id ditolak',
    $q$update public.profiles set id = gen_random_uuid() where id = auth.uid()$q$, 'permission denied');
  perform t.expect_err('eskalasi: customer insert profiles ditolak',
    $q$insert into public.profiles (id, role) values (gen_random_uuid(), 'admin')$q$, 'permission denied');
  perform t.expect_err('eskalasi: customer delete profiles ditolak', $q$delete from public.profiles where id = auth.uid()$q$, 'permission denied');
  update public.profiles set full_name = 'Cust A Baru' where id = auth.uid();
  perform t.ok('profil: update full_name sendiri diizinkan',
    (select full_name from public.profiles where id = auth.uid()) = 'Cust A Baru');
  select count(*) into v_n from public.profiles;
  perform t.ok('profil: customer hanya melihat profilnya sendiri', v_n = 1);
  update public.profiles set full_name = 'Hacked' where id = '10000000-0000-0000-0000-00000000000b';
  perform t.logout();
  perform t.ok('profil: update profil orang lain tidak berefek',
    (select full_name from public.profiles where id = '10000000-0000-0000-0000-00000000000b') is distinct from 'Hacked');
  perform t.ok('eskalasi: role customer A tetap customer',
    (select role from public.profiles where id = '10000000-0000-0000-0000-00000000000a') = 'customer');
end $$;

-- Trigger guard profil bekerja walau grant kolom diperlebar (defense in depth).
do $$
begin
  grant update on public.profiles to authenticated;
  perform t.login('10000000-0000-0000-0000-00000000000a');
  perform t.expect_err('eskalasi: trigger guard_profile_update menolak ubah role walau grant diperlebar',
    $q$update public.profiles set role = 'admin' where id = auth.uid()$q$, 'profile_role_change_forbidden');
  perform t.logout();
end $$;

-- Signup: role pada raw_user_meta_data / raw_app_meta_data diabaikan.
do $$
begin
  insert into auth.users (id, email, raw_user_meta_data, raw_app_meta_data)
  values ('10000000-0000-0000-0000-0000000000ee', 'evil@example.test',
          '{"role":"admin","full_name":"Evil"}'::jsonb, '{"role":"admin"}'::jsonb);
  perform t.ok('signup: role di raw_user_meta_data/raw_app_meta_data diabaikan (profil = customer)',
    (select role from public.profiles where id = '10000000-0000-0000-0000-0000000000ee') = 'customer');
  perform t.ok('signup: full_name dari metadata tetap dipakai',
    (select full_name from public.profiles where id = '10000000-0000-0000-0000-0000000000ee') = 'Evil');
end $$;

-- Fungsi provisioning dan tabel kebijakan tidak bisa diakses klien
do $$
begin
  perform t.login('10000000-0000-0000-0000-00000000000a');
  perform t.expect_err('eskalasi: customer tidak bisa provision_set_user_role',
    $q$select public.provision_set_user_role(auth.uid(), 'admin')$q$, 'permission denied');
  perform t.expect_err('eskalasi: customer tidak bisa provision_set_policy',
    $q$select public.provision_set_policy('cancellation_enabled', 'true')$q$, 'permission denied');
  perform t.expect_err('eskalasi: customer tidak bisa membaca ops_policy', 'select * from public.ops_policy', 'permission denied');
  perform t.expect_err('eskalasi: customer tidak bisa menulis ops_policy', $q$update public.ops_policy set value = 'true'$q$, 'permission denied');
  perform t.expect_err('eskalasi: customer tidak bisa admin_get_policies', 'select * from public.admin_get_policies()', 'admin_role_required');
  perform t.expect_err('eskalasi: customer tidak bisa admin_set_store_active',
    $q$select public.admin_set_store_active('50000000-0000-0000-0000-00000000000a', false)$q$, 'admin_role_required');
  perform t.ok('audit log: customer tidak melihat baris (RLS)', (select count(*) from public.admin_audit_log) = 0);
  perform t.login('20000000-0000-0000-0000-00000000000a');
  perform t.expect_err('eskalasi: seller tidak bisa admin_set_store_delivery_config',
    $q$select public.admin_set_store_delivery_config('50000000-0000-0000-0000-00000000000a', 1, 1)$q$, 'admin_role_required');
  perform t.expect_err('eskalasi: seller tidak bisa admin_set_product_available',
    $q$select public.admin_set_product_available('60000000-0000-0000-0000-0000000000a1', false)$q$, 'admin_role_required');
  perform t.login('30000000-0000-0000-0000-00000000000a');
  perform t.expect_err('eskalasi: driver tidak bisa admin_get_policies', 'select * from public.admin_get_policies()', 'admin_role_required');
  perform t.login('40000000-0000-0000-0000-000000000001');
  perform t.ok('admin: admin_get_policies mengembalikan default fail-closed',
    (select value from public.admin_get_policies() where key = 'cancellation_enabled') = 'false'
    and (select value from public.admin_get_policies() where key = 'manual_transfer_enabled') = 'false'
    and (select value from public.admin_get_policies() where key = 'cod_collection_recording_enabled') = 'false');
  perform t.ok('audit log: admin melihat baris', (select count(*) from public.admin_audit_log) > 0);
  perform t.expect_err('admin: admin tidak bisa provision_set_user_role (hanya service_role)',
    $q$select public.provision_set_user_role(auth.uid(), 'admin')$q$, 'permission denied');
  perform t.logout();
end $$;

-- Kepemilikan toko/produk
do $$
begin
  perform t.login('20000000-0000-0000-0000-00000000000b');  -- seller B
  perform t.expect_err('toko: seller B tidak bisa insert toko atas nama seller A',
    $q$insert into public.stores (owner_id, name, address) values ('20000000-0000-0000-0000-00000000000a', 'x', 'y')$q$, 'row-level security');
  update public.stores set name = 'Dibajak' where id = '50000000-0000-0000-0000-00000000000a';
  update public.products set price = 1 where id = '60000000-0000-0000-0000-0000000000a1';
  perform t.expect_err('produk: seller B tidak bisa insert produk ke toko A',
    $q$insert into public.products (store_id, name, price) values ('50000000-0000-0000-0000-00000000000a', 'x', 1)$q$, 'row-level security');
  delete from public.products where id = '60000000-0000-0000-0000-0000000000a2';
  perform t.expect_err('toko: seller tidak bisa mengubah is_active', $q$update public.stores set is_active = true where owner_id = auth.uid()$q$, 'permission denied');
  perform t.expect_err('toko: seller tidak bisa mengubah delivery_fee', $q$update public.stores set delivery_fee = 0 where owner_id = auth.uid()$q$, 'permission denied');
  perform t.expect_err('toko: seller tidak bisa mengubah service_radius_km', $q$update public.stores set service_radius_km = 999 where owner_id = auth.uid()$q$, 'permission denied');
  perform t.expect_err('toko: seller tidak bisa mengubah owner_id', $q$update public.stores set owner_id = '20000000-0000-0000-0000-00000000000a' where owner_id = auth.uid()$q$, 'permission denied');
  perform t.expect_err('toko: seller tidak bisa menghapus toko', $q$delete from public.stores$q$, 'permission denied');
  perform t.ok('toko: seller B tidak melihat toko nonaktif milik seller A',
    not exists (select 1 from public.stores where id = '50000000-0000-0000-0000-00000000000c'));
  perform t.ok('toko: seller B tetap melihat toko aktif milik seller A',
    exists (select 1 from public.stores where id = '50000000-0000-0000-0000-00000000000a'));
  perform t.login('20000000-0000-0000-0000-00000000000a');  -- seller A
  perform t.expect_err('toko: seller A tidak bisa pindahkan lokasi toko aktif',
    $q$update public.stores set latitude = -6.5 where id = '50000000-0000-0000-0000-00000000000a'$q$, 'store_location_locked');
  perform t.expect_err('produk: seller A tidak bisa pindahkan produk ke toko lain (store_id)',
    $q$update public.products set store_id = '50000000-0000-0000-0000-00000000000b' where id = '60000000-0000-0000-0000-0000000000a1'$q$, 'permission denied');
  update public.products set price = 10500 where id = '60000000-0000-0000-0000-0000000000a1';
  perform t.ok('produk: seller A mengubah harga produk sendiri',
    (select price from public.products where id = '60000000-0000-0000-0000-0000000000a1') = 10500);
  perform t.expect_err('produk: seller tidak bisa menetapkan harga NaN',
    $q$update public.products set price = 'NaN'::numeric where id = '60000000-0000-0000-0000-0000000000a1'$q$,
    'products_price_not_nan');
  perform t.login('10000000-0000-0000-0000-00000000000a');
  perform t.expect_err('toko: customer tidak bisa insert toko', $q$insert into public.stores (owner_id, name, address) values (auth.uid(), 'x', 'y')$q$, 'row-level security');
  perform t.expect_err('produk: customer tidak bisa insert produk',
    $q$insert into public.products (store_id, name, price) values ('50000000-0000-0000-0000-00000000000a', 'x', 1)$q$, 'row-level security');
  perform t.ok('produk: customer tidak melihat produk tidak tersedia/toko nonaktif',
    (select count(*) from public.products where id in ('60000000-0000-0000-0000-0000000000a3', '60000000-0000-0000-0000-0000000000c1')) = 0);
  perform t.logout();
  perform t.ok('toko/produk: tampering seller B tidak berefek (nama, harga, produk tetap)',
    (select name from public.stores where id = '50000000-0000-0000-0000-00000000000a') = 'Warung A'
    and exists (select 1 from public.products where id = '60000000-0000-0000-0000-0000000000a2')
    and (select price from public.products where id = '60000000-0000-0000-0000-0000000000a1') = 10500);
end $$;

-- ===== Isolasi order: pakai order e2e (A, seller A, driver A) dan order pending baru =====
do $$
declare
  v_e2e uuid := (select id from public.orders where idempotency_key = 'e2e-cod-0001');
  v_new uuid;
  v_who record;
  n int;
begin
  v_new := t.make_order('10000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-00000000000a',
    '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":1}]');

  -- Pihak yang berhak melihat
  for v_who in select * from (values
    ('customer A', '10000000-0000-0000-0000-00000000000a'::uuid),
    ('seller A',   '20000000-0000-0000-0000-00000000000a'::uuid),
    ('admin',      '40000000-0000-0000-0000-000000000001'::uuid)) as x(label, uid) loop
    perform t.login(v_who.uid);
    perform t.ok('baca: ' || v_who.label || ' melihat order, item, dan riwayat e2e',
      (select count(*) from public.orders where id = v_e2e) = 1
      and (select count(*) from public.order_items where order_id = v_e2e) = 2
      and (select count(*) from public.order_status_history where order_id = v_e2e) = 8);
  end loop;
  perform t.login('30000000-0000-0000-0000-00000000000a');
  perform t.ok('baca: driver A (ditugaskan) melihat order, item, riwayat e2e',
    (select count(*) from public.orders where id = v_e2e) = 1
    and (select count(*) from public.order_items where order_id = v_e2e) = 2
    and (select count(*) from public.order_status_history where order_id = v_e2e) = 8);
  perform t.ok('baca: driver A tidak melihat order yang tidak ditugaskan kepadanya',
    (select count(*) from public.orders where id = v_new) = 0);

  -- Pihak lain tidak bisa melihat
  for v_who in select * from (values
    ('customer B', '10000000-0000-0000-0000-00000000000b'::uuid),
    ('seller B',   '20000000-0000-0000-0000-00000000000b'::uuid),
    ('driver B',   '30000000-0000-0000-0000-00000000000b'::uuid)) as x(label, uid) loop
    perform t.login(v_who.uid);
    perform t.ok('isolasi: ' || v_who.label || ' tidak melihat orders A',
      (select count(*) from public.orders) = 0);
    perform t.ok('isolasi: ' || v_who.label || ' tidak melihat order_items A',
      (select count(*) from public.order_items) = 0);
    perform t.ok('isolasi: ' || v_who.label || ' tidak melihat riwayat status A',
      (select count(*) from public.order_status_history) = 0);
    perform t.ok('isolasi: ' || v_who.label || ' list_my_orders kosong',
      (select count(*) from public.list_my_orders()) = 0);
    perform t.expect_err('isolasi: ' || v_who.label || ' tidak bisa ubah status order A',
      format($q$select public.change_order_status(%L, 'accepted', null)$q$, v_new), 'status_transition_not_allowed');
  end loop;
  -- seller A tidak melihat order milik toko B (tidak ada), customer A list hanya miliknya
  perform t.login('10000000-0000-0000-0000-00000000000a');
  perform t.ok('list_my_orders: customer A melihat 2 order miliknya (e2e + baru)', (select count(*) from public.list_my_orders()) = 2);
  perform t.ok('list_my_orders: filter status completed -> 1 dengan item snapshot',
    (select jsonb_array_length(items) from public.list_my_orders('completed')) = 2);
  perform t.login('30000000-0000-0000-0000-00000000000a');
  perform t.ok('list_my_orders: driver A hanya melihat tugasnya (1)', (select count(*) from public.list_my_orders()) = 1);
  perform t.login('20000000-0000-0000-0000-00000000000b');
  perform t.expect_err('list_my_orders: pagination tidak valid ditolak', 'select * from public.list_my_orders(null, 0, 0)', 'invalid_pagination');
  perform t.logout();
end $$;

-- ===== Alamat tersimpan =====
do $$
declare v_a uuid; i int;
begin
  perform t.login('10000000-0000-0000-0000-00000000000a');
  insert into public.customer_addresses (label, address, latitude, longitude) values ('Rumah', 'Jl. Rumah 1', -6.21, 106.81) returning id into v_a;
  perform t.ok('alamat: customer A menyimpan alamat sendiri', (select count(*) from public.customer_addresses) = 1);
  perform t.login('10000000-0000-0000-0000-00000000000b');
  perform t.ok('alamat: customer B tidak melihat alamat A', (select count(*) from public.customer_addresses) = 0);
  update public.customer_addresses set label = 'Dibajak' where id = v_a;
  delete from public.customer_addresses where id = v_a;
  perform t.expect_err('alamat: customer B tidak bisa isi customer_id milik A',
    format($q$insert into public.customer_addresses (customer_id, label, address) values (%L, 'x', 'y')$q$, '10000000-0000-0000-0000-00000000000a'), 'permission denied');
  perform t.login('20000000-0000-0000-0000-00000000000a');
  perform t.expect_err('alamat: seller tidak bisa menyimpan alamat customer',
    $q$insert into public.customer_addresses (label, address) values ('x', 'y')$q$, 'row-level security');
  perform t.login('10000000-0000-0000-0000-00000000000a');
  perform t.ok('alamat: update/delete B tidak berefek pada alamat A',
    (select label from public.customer_addresses where id = v_a) = 'Rumah');
  for i in 2..10 loop
    insert into public.customer_addresses (label, address) values ('A' || i, 'Jl. ' || i);
  end loop;
  perform t.expect_err('alamat: batas 10 alamat per customer', $q$insert into public.customer_addresses (label, address) values ('11', 'x')$q$, 'address_limit_reached');
  perform t.logout();
end $$;

-- ===== Penulisan langsung ke order =====
do $$
declare v_e2e uuid := (select id from public.orders where idempotency_key = 'e2e-cod-0001');
begin
  perform t.login('10000000-0000-0000-0000-00000000000a');
  perform t.expect_err('direct: customer insert orders ditolak',
    $q$insert into public.orders (customer_id, store_id, delivery_address, subtotal, delivery_fee, total, payment_method)
       values (auth.uid(), '50000000-0000-0000-0000-00000000000a', 'x', 1, 0, 1, 'cod')$q$, 'permission denied');
  perform t.expect_err('direct: customer update orders (total) ditolak', format($q$update public.orders set total = 1, subtotal = 1, delivery_fee = 0 where id = %L$q$, v_e2e), 'permission denied');
  perform t.expect_err('direct: customer update payment_status ditolak', format($q$update public.orders set payment_status = 'verified' where id = %L$q$, v_e2e), 'permission denied');
  perform t.expect_err('direct: customer update order_status ditolak', format($q$update public.orders set order_status = 'completed' where id = %L$q$, v_e2e), 'permission denied');
  perform t.expect_err('direct: customer delete orders ditolak', 'delete from public.orders', 'permission denied');
  perform t.expect_err('direct: customer insert order_items ditolak',
    format($q$insert into public.order_items (order_id, product_name_snapshot, unit_price_snapshot, quantity, line_total) values (%L, 'x', 0, 1, 0)$q$, v_e2e), 'permission denied');
  perform t.expect_err('direct: customer update order_items ditolak', 'update public.order_items set unit_price_snapshot = 0', 'permission denied');
  perform t.expect_err('direct: customer delete order_items ditolak', 'delete from public.order_items', 'permission denied');
  perform t.expect_err('direct: customer insert riwayat ditolak',
    format($q$insert into public.order_status_history (order_id, new_status) values (%L, 'completed')$q$, v_e2e), 'permission denied');
  perform t.expect_err('direct: customer update riwayat ditolak', 'update public.order_status_history set note = null', 'permission denied');
  perform t.expect_err('direct: customer delete riwayat ditolak', 'delete from public.order_status_history', 'permission denied');
  perform t.login('20000000-0000-0000-0000-00000000000a');
  perform t.expect_err('direct: seller update orders ditolak', 'update public.orders set order_status = ''accepted''', 'permission denied');
  perform t.login('30000000-0000-0000-0000-00000000000a');
  perform t.expect_err('direct: driver update orders ditolak', 'update public.orders set order_status = ''delivered''', 'permission denied');
  perform t.login('40000000-0000-0000-0000-000000000001');
  perform t.expect_err('direct: admin pun tidak bisa update orders langsung', 'update public.orders set order_status = ''completed''', 'permission denied');
  perform t.logout();
end $$;

-- Defense in depth: bila grant/policy suatu hari longgar, trigger tetap menolak.
do $$
declare v_e2e uuid := (select id from public.orders where idempotency_key = 'e2e-cod-0001');
begin
  grant insert, update, delete on public.orders, public.order_items, public.order_status_history to authenticated;
  create policy tmp_all_orders on public.orders for all to authenticated using (true) with check (true);
  create policy tmp_all_items on public.order_items for all to authenticated using (true) with check (true);
  create policy tmp_all_hist on public.order_status_history for all to authenticated using (true) with check (true);
  perform t.login('10000000-0000-0000-0000-00000000000a');
  perform t.expect_err('trigger: insert orders ditolak walau grant+RLS longgar',
    $q$insert into public.orders (customer_id, store_id, delivery_address, subtotal, delivery_fee, total, payment_method)
       values (auth.uid(), '50000000-0000-0000-0000-00000000000a', 'x', 1, 0, 1, 'cod')$q$, 'direct_write_forbidden');
  perform t.expect_err('trigger: update orders ditolak walau grant+RLS longgar', format($q$update public.orders set payment_status = 'verified' where id = %L$q$, v_e2e), 'direct_write_forbidden');
  perform t.expect_err('trigger: delete orders ditolak walau grant+RLS longgar', format($q$delete from public.orders where id = %L$q$, v_e2e), 'direct_write_forbidden');
  perform t.expect_err('trigger: update order_items ditolak walau grant+RLS longgar', 'update public.order_items set unit_price_snapshot = 0', 'direct_write_forbidden');
  perform t.expect_err('trigger: delete order_status_history ditolak walau grant+RLS longgar', 'delete from public.order_status_history', 'direct_write_forbidden');
  perform t.logout();
end $$;

rollback;
