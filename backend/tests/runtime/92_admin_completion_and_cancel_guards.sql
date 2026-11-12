-- Guard admin untuk completed + larang batal dari status terminal
-- (migrasi 20261112000002, keputusan pemilik 12 Nov 2026):
-- batal dari completed/cancelled/rejected ditolak untuk SEMUA aktor termasuk admin;
-- admin menandai selesai wajib alasan; driver/pelanggan/penjual yang menyelesaikan
-- sesuai completion_actor tetap tanpa alasan wajib; aturan batal customer/seller
-- tidak berubah.
-- Semua dalam satu transaksi yang di-rollback.
\set ON_ERROR_STOP on
begin;

do $$
declare
  cA constant uuid := '10000000-0000-0000-0000-00000000000a';
  cB constant uuid := '10000000-0000-0000-0000-00000000000b';
  sA constant uuid := '20000000-0000-0000-0000-00000000000a';
  sB constant uuid := '20000000-0000-0000-0000-00000000000b';
  dA constant uuid := '30000000-0000-0000-0000-00000000000a';
  adm constant uuid := '40000000-0000-0000-0000-000000000001';
  storeA constant uuid := '50000000-0000-0000-0000-00000000000a';
  items constant jsonb := '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":1}]';
  o uuid; v text;
begin
  -- Admin batal dari completed: ditolak (dulu lolos, melewati daftar status).
  o := t.make_order(cA, storeA, items);
  perform t.status_as(sA, o, 'accepted');
  perform t.status_as(sA, o, 'preparing');
  perform t.login(adm); perform public.assign_order_driver(o, dA); perform t.logout();
  perform t.status_as(sA, o, 'ready_for_pickup');
  perform t.status_as(dA, o, 'picked_up');
  perform t.status_as(dA, o, 'delivered');
  perform t.status_as(cA, o, 'completed');
  v := format('select public.change_order_status(%L, %%L, %%L)', o);
  perform t.login(adm);
  perform t.expect_err('guard: admin batal dari completed ditolak', format(v, 'cancelled', 'komplain'), 'cancel_from_terminal_status_not_allowed');
  perform t.logout();
  perform t.ok('guard: status tetap completed setelah admin batal ditolak',
    (select order_status from public.orders where id = o) = 'completed');

  -- Admin batal dari cancelled: ditolak (batal ganda).
  o := t.make_order(cA, storeA, items);
  perform t.status_as(cA, o, 'cancelled', 'berubah pikiran');
  v := format('select public.change_order_status(%L, %%L, %%L)', o);
  perform t.login(adm);
  perform t.expect_err('guard: admin batal dari cancelled ditolak', format(v, 'cancelled', 'batal lagi'), 'cancel_from_terminal_status_not_allowed');
  perform t.logout();
  perform t.ok('guard: status tetap cancelled setelah admin batal ditolak',
    (select order_status from public.orders where id = o) = 'cancelled');

  -- Admin batal dari rejected: ditolak.
  o := t.make_order(cA, storeA, items);
  perform t.status_as(sA, o, 'rejected', 'stok habis');
  v := format('select public.change_order_status(%L, %%L, %%L)', o);
  perform t.login(adm);
  perform t.expect_err('guard: admin batal dari rejected ditolak', format(v, 'cancelled', 'batal'), 'cancel_from_terminal_status_not_allowed');
  perform t.logout();
  perform t.ok('guard: status tetap rejected setelah admin batal ditolak',
    (select order_status from public.orders where id = o) = 'rejected');

  -- Admin batal dari delivered + alasan: tetap lolos (bypass daftar status non-terminal).
  o := t.make_order(cA, storeA, items);
  perform t.status_as(sA, o, 'accepted');
  perform t.status_as(sA, o, 'preparing');
  perform t.login(adm); perform public.assign_order_driver(o, dA); perform t.logout();
  perform t.status_as(sA, o, 'ready_for_pickup');
  perform t.status_as(dA, o, 'picked_up');
  perform t.status_as(dA, o, 'delivered');
  perform t.status_as(adm, o, 'cancelled', 'komplain pelanggan');
  perform t.ok('guard: admin batal dari delivered tetap lolos',
    (select order_status from public.orders where id = o) = 'cancelled');

  -- Admin selesai tanpa alasan: ditolak (dulu lolos lewat RPC langsung).
  o := t.make_order(cA, storeA, items);
  perform t.status_as(sA, o, 'accepted');
  perform t.status_as(sA, o, 'preparing');
  perform t.login(adm); perform public.assign_order_driver(o, dA); perform t.logout();
  perform t.status_as(sA, o, 'ready_for_pickup');
  perform t.status_as(dA, o, 'picked_up');
  perform t.status_as(dA, o, 'delivered');
  v := format('select public.change_order_status(%L, %%L, %%L)', o);
  perform t.login(adm);
  perform t.expect_err('guard: admin selesai tanpa alasan (null) ditolak', format(v, 'completed', null), 'completion_reason_required');
  perform t.expect_err('guard: admin selesai tanpa alasan (spasi) ditolak', format(v, 'completed', '  '), 'completion_reason_required');
  perform t.logout();
  perform t.ok('guard: status tetap delivered setelah admin selesai tanpa alasan ditolak',
    (select order_status from public.orders where id = o) = 'delivered');

  -- Admin selesai + alasan: lolos, riwayat mencatat alasan + pelaku admin.
  perform t.status_as(adm, o, 'completed', 'pesanan diterima dengan baik');
  perform t.ok('guard: admin selesai + alasan lolos',
    (select order_status from public.orders where id = o) = 'completed'
    and exists (select 1 from public.order_status_history where order_id = o and new_status = 'completed' and changed_by = adm and note = 'pesanan diterima dengan baik'));

  -- Driver selesai tanpa alasan: tetap lolos (completion_actor = driver).
  perform public.provision_set_policy('completion_actor', 'driver');
  o := t.make_order(cA, storeA, items);
  perform t.status_as(sA, o, 'accepted');
  perform t.status_as(sA, o, 'preparing');
  perform t.login(adm); perform public.assign_order_driver(o, dA); perform t.logout();
  perform t.status_as(sA, o, 'ready_for_pickup');
  perform t.status_as(dA, o, 'picked_up');
  perform t.status_as(dA, o, 'delivered');
  perform t.status_as(dA, o, 'completed');
  perform t.ok('guard: driver selesai tanpa alasan tetap lolos',
    (select order_status from public.orders where id = o) = 'completed'
    and (select payment_status from public.orders where id = o) = 'unpaid');
  perform public.provision_set_policy('completion_actor', 'customer');

  -- Regresi: aturan batal customer/seller tidak berubah.
  o := t.make_order(cA, storeA, items);
  perform t.status_as(sA, o, 'accepted');
  v := format('select public.change_order_status(%L, %%L, %%L)', o);
  perform t.login(cA);
  perform t.expect_err('guard: customer dari accepted tetap ditolak', format(v, 'cancelled', 'alasan'), 'status_transition_not_allowed');
  perform t.logout();
  perform t.status_as(sA, o, 'preparing');
  perform t.status_as(sA, o, 'ready_for_pickup');
  perform t.login(sA);
  perform t.expect_err('guard: seller dari ready_for_pickup tetap ditolak', format(v, 'cancelled', 'alasan'), 'status_transition_not_allowed');
  perform t.logout();
end $$;

rollback;
