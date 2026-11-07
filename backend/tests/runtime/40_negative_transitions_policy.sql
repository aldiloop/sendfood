-- Negatif transisi/aktor, penugasan driver, kebijakan fail-closed (cancellation, COD collection).
-- Semua dalam satu transaksi yang di-rollback; created_at riwayat sama sehingga urutan tidak dinilai di sini.
\set ON_ERROR_STOP on
begin;

do $$
declare
  cA constant uuid := '10000000-0000-0000-0000-00000000000a';
  cB constant uuid := '10000000-0000-0000-0000-00000000000b';
  sA constant uuid := '20000000-0000-0000-0000-00000000000a';
  sB constant uuid := '20000000-0000-0000-0000-00000000000b';
  dA constant uuid := '30000000-0000-0000-0000-00000000000a';
  dB constant uuid := '30000000-0000-0000-0000-00000000000b';
  adm constant uuid := '40000000-0000-0000-0000-000000000001';
  storeA constant uuid := '50000000-0000-0000-0000-00000000000a';
  items constant jsonb := '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":1}]';
  o uuid; o2 uuid; v text;
begin
  o := t.make_order(cA, storeA, items);
  v := format('select public.change_order_status(%L, %%L, %%L)', o);

  -- Aktor salah pada pending_seller
  perform t.login(cA);
  perform t.expect_err('aktor: customer tidak bisa accept', format(v, 'accepted', null), 'status_transition_not_allowed');
  perform t.login(sB);
  perform t.expect_err('aktor: seller B (bukan pemilik) tidak bisa accept', format(v, 'accepted', null), 'status_transition_not_allowed');
  perform t.login(dA);
  perform t.expect_err('aktor: driver tidak bisa accept', format(v, 'accepted', null), 'status_transition_not_allowed');
  perform t.login(sA);
  -- Transisi loncat
  perform t.expect_err('transisi: pending_seller -> preparing (loncat) ditolak', format(v, 'preparing', null), 'status_transition_not_allowed');
  perform t.expect_err('transisi: pending_seller -> ready_for_pickup ditolak', format(v, 'ready_for_pickup', null), 'status_transition_not_allowed');
  perform t.expect_err('transisi: pending_seller -> delivered ditolak', format(v, 'delivered', null), 'status_transition_not_allowed');
  perform t.expect_err('transisi: pending_seller -> completed ditolak', format(v, 'completed', null), 'status_transition_not_allowed');
  perform t.expect_err('transisi: pending_seller -> pending_seller (tanpa perubahan) ditolak', format(v, 'pending_seller', null), 'status_transition_not_allowed');
  perform t.expect_err('reject: tanpa alasan ditolak', format(v, 'rejected', '  '), 'rejection_reason_required');
  perform t.expect_err('order tak ada: ditolak', 'select public.change_order_status(gen_random_uuid(), ''accepted'', null)', 'order_not_found');
  perform t.expect_err('catatan status > 500 karakter ditolak', format(v, 'accepted', repeat('x', 501)), 'status_note_too_long');

  -- Cancellation fail closed
  perform t.expect_err('cancel: seller ditolak, kebijakan belum dikonfigurasi', format(v, 'cancelled', 'alasan'), 'cancellation_policy_not_configured');
  perform t.login(cA);
  perform t.expect_err('cancel: customer ditolak, kebijakan belum dikonfigurasi', format(v, 'cancelled', 'alasan'), 'cancellation_policy_not_configured');
  perform t.login(adm);
  perform t.expect_err('cancel: admin pun ditolak, kebijakan belum dikonfigurasi', format(v, 'cancelled', 'alasan'), 'cancellation_policy_not_configured');
  perform t.logout();
  perform public.provision_set_policy('cancellation_enabled', 'true');
  perform t.login(cA);
  perform t.expect_err('cancel: enabled=true tanpa cancellation_allowed_statuses tetap ditolak', format(v, 'cancelled', 'alasan'), 'cancellation_policy_not_configured');
  perform t.logout();

  -- Seller menerima
  perform t.status_as(sA, o, 'accepted');
  perform t.login(sA);
  perform t.expect_err('transisi: accepted -> ready_for_pickup (loncat) ditolak', format(v, 'ready_for_pickup', null), 'status_transition_not_allowed');
  perform t.expect_err('transisi: accepted -> picked_up ditolak', format(v, 'picked_up', null), 'status_transition_not_allowed');
  perform t.expect_err('transisi: accepted -> pending_seller (mundur) ditolak', format(v, 'pending_seller', null), 'status_transition_not_allowed');
  perform t.expect_err('transisi: accepted -> rejected ditolak', format(v, 'rejected', 'terlambat'), 'status_transition_not_allowed');
  perform t.login(cB);
  perform t.expect_err('aktor: customer B tidak bisa ubah status order A', format(v, 'preparing', null), 'status_transition_not_allowed');

  -- Penugasan driver: negatif
  perform t.login(sA);
  perform t.expect_err('assign: seller tidak bisa assign', format('select public.assign_order_driver(%L, %L)', o, dA), 'admin_role_required');
  perform t.login(dA);
  perform t.expect_err('assign: driver tidak bisa assign diri sendiri', format('select public.assign_order_driver(%L, %L)', o, dA), 'admin_role_required');
  perform t.login(cA);
  perform t.expect_err('assign: customer tidak bisa assign', format('select public.assign_order_driver(%L, %L)', o, dA), 'admin_role_required');
  perform t.login(adm);
  perform t.expect_err('assign: ke customer ditolak (bukan driver)', format('select public.assign_order_driver(%L, %L)', o, cB), 'driver_profile_required');
  perform t.expect_err('assign: ke seller ditolak (bukan driver)', format('select public.assign_order_driver(%L, %L)', o, sA), 'driver_profile_required');
  perform t.expect_err('assign: ke admin ditolak (bukan driver)', format('select public.assign_order_driver(%L, %L)', o, adm), 'driver_profile_required');
  perform t.expect_err('assign: ke id acak ditolak', format('select public.assign_order_driver(%L, gen_random_uuid())', o), 'driver_profile_required');
  perform t.expect_err('assign: driver null ditolak', format('select public.assign_order_driver(%L, null)', o), 'driver_profile_required');
  perform t.expect_err('assign: order tak ada ditolak', format('select public.assign_order_driver(gen_random_uuid(), %L)', dA), 'order_not_found');
  perform t.logout();
  perform t.ok('assign: tidak ada driver yang terpasang setelah penolakan', (select driver_id from public.orders where id = o) is null);

  -- Admin boleh memaksa picked_up hanya bila driver terpasang
  perform t.status_as(sA, o, 'preparing');
  perform t.status_as(sA, o, 'ready_for_pickup');
  perform t.login(adm);
  perform t.expect_err('driver_not_assigned: picked_up tanpa driver ditolak', format(v, 'picked_up', null), 'driver_not_assigned');
  perform t.login(dB);
  perform t.expect_err('aktor: driver B (tak ditugaskan) tidak bisa picked_up', format(v, 'picked_up', null), 'status_transition_not_allowed');
  perform t.login(dA);
  perform t.expect_err('aktor: driver A (belum ditugaskan) tidak bisa picked_up', format(v, 'picked_up', null), 'status_transition_not_allowed');

  -- Penugasan dan re-assign sebelum pickup
  perform t.login(adm);
  perform public.assign_order_driver(o, dA);
  perform public.assign_order_driver(o, dB);
  perform public.assign_order_driver(o, dA);
  perform t.ok('assign: reassign sebelum pickup diizinkan dan tercatat di riwayat + audit',
    (select count(*) from public.order_status_history where order_id = o and note like 'driver_%') = 3
    and (select count(*) from public.admin_audit_log where action = 'assign_order_driver' and target_id = o::text) = 3);
  perform public.assign_order_driver(o, dA);
  perform t.ok('assign: assign ulang driver yang sama no-op (tanpa riwayat tambahan)',
    (select count(*) from public.order_status_history where order_id = o and note like 'driver_%') = 3);
  perform t.login(dB);
  perform t.expect_err('aktor: driver B bukan driver terpasang tidak bisa picked_up', format(v, 'picked_up', null), 'status_transition_not_allowed');
  perform t.login(sA);
  perform t.expect_err('aktor: seller tidak bisa picked_up', format(v, 'picked_up', null), 'status_transition_not_allowed');
  perform t.login(dA);
  perform t.expect_err('transisi: driver A ready_for_pickup -> delivered (loncat) ditolak', format(v, 'delivered', null), 'status_transition_not_allowed');
  perform t.status_as(dA, o, 'picked_up');
  perform t.login(adm);
  perform t.expect_err('assign: setelah picked_up tidak bisa assign ulang', format('select public.assign_order_driver(%L, %L)', o, dB), 'order_not_assignable');

  -- Delivery dan completion
  perform t.login(dB);
  perform t.expect_err('aktor: driver B tidak bisa delivered', format(v, 'delivered', null), 'status_transition_not_allowed');
  perform t.login(sA);
  perform t.expect_err('aktor: seller tidak bisa delivered', format(v, 'delivered', null), 'status_transition_not_allowed');
  perform t.login(cA);
  perform t.expect_err('aktor: customer tidak bisa delivered', format(v, 'delivered', null), 'status_transition_not_allowed');
  perform t.expect_err('transisi: customer picked_up -> completed (loncat) ditolak', format(v, 'completed', null), 'status_transition_not_allowed');
  perform t.status_as(dA, o, 'delivered');
  perform t.login(dA);
  perform t.expect_err('completion: driver tidak diizinkan (aktor kebijakan = customer)', format(v, 'completed', null), 'status_transition_not_allowed');
  perform t.login(sA);
  perform t.expect_err('completion: seller tidak diizinkan (aktor kebijakan = customer)', format(v, 'completed', null), 'status_transition_not_allowed');
  perform t.login(cB);
  perform t.expect_err('completion: customer B tidak diizinkan', format(v, 'completed', null), 'status_transition_not_allowed');
  perform t.login(cA);
  perform t.expect_err('cancel: setelah delivered ditolak', format(v, 'cancelled', 'alasan'), 'cancellation_policy_not_configured');
  perform t.status_as(cA, o, 'completed');
  perform t.login(adm);
  perform t.expect_err('terminal: completed -> delivered (mundur) ditolak', format(v, 'delivered', null), 'status_transition_not_allowed');
  perform t.expect_err('terminal: completed -> completed ditolak', format(v, 'completed', null), 'status_transition_not_allowed');
  perform t.expect_err('terminal: completed -> accepted ditolak', format(v, 'accepted', null), 'status_transition_not_allowed');
  perform t.logout();
  perform t.ok('pembayaran: setelah delivered+completed payment_status tetap unpaid', (select payment_status from public.orders where id = o) = 'unpaid');

  -- Aktor completion mengikuti kebijakan
  perform public.provision_set_policy('completion_actor', 'seller');
  o2 := t.make_order(cA, storeA, items);
  perform t.status_as(sA, o2, 'accepted');
  perform t.status_as(sA, o2, 'preparing');
  perform t.login(adm);  perform public.assign_order_driver(o2, dA);  perform t.logout();
  perform t.status_as(sA, o2, 'ready_for_pickup');
  perform t.status_as(dA, o2, 'picked_up');
  perform t.status_as(dA, o2, 'delivered');
  perform t.login(cA);
  perform t.expect_err('completion: customer ditolak bila kebijakan = seller', format('select public.change_order_status(%L, ''completed'', null)', o2), 'status_transition_not_allowed');
  perform t.login(sB);
  perform t.expect_err('completion: seller B (bukan pemilik) ditolak', format('select public.change_order_status(%L, ''completed'', null)', o2), 'status_transition_not_allowed');
  perform t.status_as(sA, o2, 'completed');
  perform t.ok('completion: seller pemilik diizinkan bila kebijakan = seller', (select order_status from public.orders where id = o2) = 'completed');
  perform t.ok('pembayaran: completion oleh seller juga tidak melunasi', (select payment_status from public.orders where id = o2) = 'unpaid');
  perform t.expect_err('kebijakan: nilai completion_actor tidak valid ditolak', $q$select public.provision_set_policy('completion_actor', 'admin')$q$, 'invalid_policy_value');
  perform t.expect_err('kebijakan: kunci tak dikenal ditolak', $q$select public.provision_set_policy('nonsense', 'true')$q$, 'unknown_policy_key');
end $$;

-- Rejection dan cancellation dengan kebijakan dikonfigurasi
do $$
declare
  cA constant uuid := '10000000-0000-0000-0000-00000000000a';
  cB constant uuid := '10000000-0000-0000-0000-00000000000b';
  sA constant uuid := '20000000-0000-0000-0000-00000000000a';
  sB constant uuid := '20000000-0000-0000-0000-00000000000b';
  dA constant uuid := '30000000-0000-0000-0000-00000000000a';
  adm constant uuid := '40000000-0000-0000-0000-000000000001';
  items constant jsonb := '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":1}]';
  o uuid; v text;
begin
  o := t.make_order(cA, '50000000-0000-0000-0000-00000000000a', items);
  v := format('select public.change_order_status(%L, %%L, %%L)', o);
  perform t.status_as(sA, o, 'rejected', 'stok habis');
  perform t.ok('reject: seller menolak dengan alasan tercatat di riwayat',
    (select order_status from public.orders where id = o) = 'rejected'
    and exists (select 1 from public.order_status_history where order_id = o and new_status = 'rejected' and note = 'stok habis'));
  perform t.login(adm);
  perform t.expect_err('terminal: rejected -> accepted ditolak', format(v, 'accepted', null), 'status_transition_not_allowed');
  perform t.logout();

  -- cancellation_enabled=true (dari blok sebelumnya sudah true) + status yang diizinkan
  perform public.provision_set_policy('cancellation_enabled', 'true');
  perform t.expect_err('kebijakan: cancellation_allowed_statuses dengan status terminal ditolak',
    $q$select public.provision_set_policy('cancellation_allowed_statuses', 'completed')$q$, 'invalid_policy_value');
  perform public.provision_set_policy('cancellation_allowed_statuses', 'pending_seller,accepted');
  o := t.make_order(cA, '50000000-0000-0000-0000-00000000000a', items);
  v := format('select public.change_order_status(%L, %%L, %%L)', o);
  perform t.login(cA);
  perform t.expect_err('cancel: tanpa alasan ditolak', format(v, 'cancelled', null), 'cancellation_reason_required');
  perform t.login(cB);
  perform t.expect_err('cancel: customer B ditolak', format(v, 'cancelled', 'iseng'), 'status_transition_not_allowed');
  perform t.login(sB);
  perform t.expect_err('cancel: seller B ditolak', format(v, 'cancelled', 'iseng'), 'status_transition_not_allowed');
  perform t.login(dA);
  perform t.expect_err('cancel: driver ditolak', format(v, 'cancelled', 'iseng'), 'status_transition_not_allowed');
  perform t.logout();
  perform t.status_as(sA, o, 'accepted');
  perform t.status_as(sA, o, 'preparing');
  perform t.login(cA);
  perform t.expect_err('cancel: status preparing tidak termasuk yang diizinkan', format(v, 'cancelled', 'batal'), 'status_transition_not_allowed');
  perform t.logout();

  o := t.make_order(cA, '50000000-0000-0000-0000-00000000000a', items);
  perform t.status_as(cA, o, 'cancelled', 'salah pesan');
  perform t.ok('cancel: customer pemilik berhasil membatalkan saat pending_seller bila kebijakan dikonfigurasi',
    (select order_status from public.orders where id = o) = 'cancelled'
    and exists (select 1 from public.order_status_history where order_id = o and new_status = 'cancelled' and changed_by = cA and note = 'salah pesan'));
  perform t.ok('cancel: payment_status tidak disentuh (refund belum diputuskan)', (select payment_status from public.orders where id = o) = 'unpaid');
end $$;

-- COD collection fail closed
do $$
declare
  cA constant uuid := '10000000-0000-0000-0000-00000000000a';
  sA constant uuid := '20000000-0000-0000-0000-00000000000a';
  dA constant uuid := '30000000-0000-0000-0000-00000000000a';
  dB constant uuid := '30000000-0000-0000-0000-00000000000b';
  adm constant uuid := '40000000-0000-0000-0000-000000000001';
  items constant jsonb := '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":1}]';
  o uuid; q text;
begin
  o := t.make_order(cA, '50000000-0000-0000-0000-00000000000a', items);
  q := format('select public.record_cod_collection(%L)', o);
  perform t.login(adm);
  perform t.expect_err('cod: admin ditolak, kebijakan belum dikonfigurasi', q, 'cod_collection_policy_not_configured');
  perform t.login(dA);
  perform t.expect_err('cod: driver ditolak, kebijakan belum dikonfigurasi', q, 'cod_collection_policy_not_configured');
  perform t.login(cA);
  perform t.expect_err('cod: customer ditolak, kebijakan belum dikonfigurasi', q, 'cod_collection_policy_not_configured');
  perform t.logout();
  perform public.provision_set_policy('cod_collection_recording_enabled', 'true');
  perform t.login(adm);
  perform t.expect_err('cod: enabled=true tanpa cod_collection_actor tetap ditolak', q, 'cod_collection_policy_not_configured');
  perform t.logout();
  perform t.expect_err('kebijakan: cod_collection_actor customer tidak valid', $q$select public.provision_set_policy('cod_collection_actor', 'customer')$q$, 'invalid_policy_value');
  perform public.provision_set_policy('cod_collection_actor', 'admin');

  -- Kebijakan aktif tetapi order belum delivered
  perform t.login(adm);
  perform t.expect_err('cod: order belum delivered ditolak', q, 'order_not_delivered');
  perform t.login(dA);
  perform t.expect_err('cod: driver ditolak bila aktor kebijakan = admin', q, 'status_transition_not_allowed');
  perform t.logout();

  -- Selesaikan order lalu catat penerimaan secara eksplisit
  perform t.status_as(sA, o, 'accepted');
  perform t.status_as(sA, o, 'preparing');
  perform t.login(adm); perform public.assign_order_driver(o, dA); perform t.logout();
  perform t.status_as(sA, o, 'ready_for_pickup');
  perform t.status_as(dA, o, 'picked_up');
  perform t.status_as(dA, o, 'delivered');
  perform t.ok('cod: setelah delivered payment_status masih unpaid', (select payment_status from public.orders where id = o) = 'unpaid');
  perform t.login(cA);
  perform t.expect_err('cod: customer tidak boleh mencatat penerimaan', q, 'status_transition_not_allowed');
  perform t.login(sA);
  perform t.expect_err('cod: seller tidak boleh mencatat penerimaan', q, 'status_transition_not_allowed');
  perform t.login(adm);
  perform public.record_cod_collection(o, 'diterima tunai');
  perform t.logout();
  perform t.ok('cod: admin mencatat penerimaan eksplisit -> verified (hanya lewat aksi eksplisit)',
    (select payment_status from public.orders where id = o) = 'verified');
  perform t.login(adm);
  perform t.expect_err('cod: pencatatan ganda ditolak', q, 'payment_already_recorded');
  perform t.logout();

  -- Aktor driver
  perform public.provision_set_policy('cod_collection_actor', 'driver');
  o := t.make_order(cA, '50000000-0000-0000-0000-00000000000a', items);
  q := format('select public.record_cod_collection(%L)', o);
  perform t.status_as(sA, o, 'accepted');
  perform t.status_as(sA, o, 'preparing');
  perform t.login(adm); perform public.assign_order_driver(o, dA); perform t.logout();
  perform t.status_as(sA, o, 'ready_for_pickup');
  perform t.status_as(dA, o, 'picked_up');
  perform t.login(dA);
  perform t.expect_err('cod: sebelum delivered ditolak (picked_up)', q, 'order_not_delivered');
  perform t.logout();
  perform t.status_as(dA, o, 'delivered');
  perform t.login(dB);
  perform t.expect_err('cod: driver B (bukan driver order) ditolak', q, 'status_transition_not_allowed');
  perform t.login(dA);
  perform public.record_cod_collection(o);
  perform t.logout();
  perform t.ok('cod: driver terpasang mencatat bila kebijakan = driver', (select payment_status from public.orders where id = o) = 'verified');
end $$;

-- manual_transfer tidak pernah menjadi pembayaran valid, dan tidak ada order non-COD
do $$
begin
  perform t.ok('pembayaran: tidak ada order selain COD', not exists (select 1 from public.orders where payment_method <> 'cod'));
end $$;

rollback;
