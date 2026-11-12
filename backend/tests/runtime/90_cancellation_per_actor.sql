-- Pembatalan per aktor (migrasi 20261112000000, keputusan pemilik 12 Nov 2026):
-- customer hanya dari pending_seller; seller dari pending_seller, accepted, preparing;
-- admin dari status mana pun; alasan wajib; payment_status tidak disentuh.
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
  -- Seed dari migrasi.
  perform t.ok('cancel: seed kebijakan pembatalan per aktor',
    (select value from public.ops_policy where key = 'cancellation_enabled') = 'true'
    and (select value from public.ops_policy where key = 'cancellation_allowed_statuses') = 'pending_seller'
    and (select value from public.ops_policy where key = 'cancellation_allowed_statuses_seller') = 'pending_seller,accepted,preparing');

  -- Customer batal dari pending_seller: OK, riwayat tercatat, payment_status tidak disentuh.
  o := t.make_order(cA, storeA, items);
  perform t.status_as(cA, o, 'cancelled', 'berubah pikiran');
  perform t.ok('cancel: customer batal dari pending_seller',
    (select order_status from public.orders where id = o) = 'cancelled'
    and exists (select 1 from public.order_status_history where order_id = o and new_status = 'cancelled' and changed_by = cA and note = 'berubah pikiran'));
  perform t.ok('cancel: payment_status tidak disentuh saat batal',
    (select payment_status from public.orders where id = o) = 'unpaid');

  -- Customer batal dari accepted: ditolak (hanya pending_seller).
  o := t.make_order(cA, storeA, items);
  perform t.status_as(sA, o, 'accepted');
  v := format('select public.change_order_status(%L, %%L, %%L)', o);
  perform t.login(cA);
  perform t.expect_err('cancel: customer dari accepted ditolak', format(v, 'cancelled', 'alasan'), 'status_transition_not_allowed');
  perform t.logout();
  -- Seller (pemilik toko) batal dari accepted: OK.
  perform t.status_as(sA, o, 'cancelled', 'toko tutup');
  perform t.ok('cancel: seller batal dari accepted',
    (select order_status from public.orders where id = o) = 'cancelled');

  -- Seller batal dari preparing: OK.
  o := t.make_order(cA, storeA, items);
  perform t.status_as(sA, o, 'accepted');
  perform t.status_as(sA, o, 'preparing');
  perform t.status_as(sA, o, 'cancelled', 'bahan habis');
  perform t.ok('cancel: seller batal dari preparing',
    (select order_status from public.orders where id = o) = 'cancelled');

  -- Seller batal dari ready_for_pickup: ditolak (tidak boleh setelah preparing).
  o := t.make_order(cA, storeA, items);
  perform t.status_as(sA, o, 'accepted');
  perform t.status_as(sA, o, 'preparing');
  perform t.status_as(sA, o, 'ready_for_pickup');
  v := format('select public.change_order_status(%L, %%L, %%L)', o);
  perform t.login(sA);
  perform t.expect_err('cancel: seller dari ready_for_pickup ditolak', format(v, 'cancelled', 'alasan'), 'status_transition_not_allowed');
  perform t.logout();

  -- Admin batal dari delivered: OK (melewati daftar status).
  o := t.make_order(cA, storeA, items);
  perform t.status_as(sA, o, 'accepted');
  perform t.status_as(sA, o, 'preparing');
  perform t.login(adm); perform public.assign_order_driver(o, dA); perform t.logout();
  perform t.status_as(sA, o, 'ready_for_pickup');
  perform t.status_as(dA, o, 'picked_up');
  perform t.status_as(dA, o, 'delivered');
  perform t.status_as(adm, o, 'cancelled', 'komplain pelanggan');
  perform t.ok('cancel: admin batal dari delivered',
    (select order_status from public.orders where id = o) = 'cancelled');

  -- Tanpa alasan: ditolak untuk semua aktor.
  o := t.make_order(cA, storeA, items);
  v := format('select public.change_order_status(%L, %%L, %%L)', o);
  perform t.login(cA);
  perform t.expect_err('cancel: tanpa alasan ditolak', format(v, 'cancelled', null), 'cancellation_reason_required');
  perform t.logout();
  perform t.login(adm);
  perform t.expect_err('cancel: admin tanpa alasan juga ditolak', format(v, 'cancelled', '  '), 'cancellation_reason_required');
  perform t.logout();

  -- Driver bukan aktor pembatalan.
  perform t.login(dA);
  perform t.expect_err('cancel: driver ditolak', format(v, 'cancelled', 'alasan'), 'status_transition_not_allowed');
  perform t.logout();
  -- Customer lain (bukan pemilik order) ditolak.
  perform t.login(cB);
  perform t.expect_err('cancel: customer lain ditolak', format(v, 'cancelled', 'alasan'), 'status_transition_not_allowed');
  perform t.logout();
  -- Seller lain (bukan pemilik toko) ditolak.
  perform t.login(sB);
  perform t.expect_err('cancel: seller lain ditolak', format(v, 'cancelled', 'alasan'), 'status_transition_not_allowed');
  perform t.logout();

  -- Master switch dimatikan: semua ditolak cancellation_policy_not_configured.
  perform public.provision_set_policy('cancellation_enabled', 'false');
  perform t.login(cA);
  perform t.expect_err('cancel: saat dimatikan, customer ditolak', format(v, 'cancelled', 'alasan'), 'cancellation_policy_not_configured');
  perform t.logout();
  perform t.login(adm);
  perform t.expect_err('cancel: saat dimatikan, admin pun ditolak', format(v, 'cancelled', 'alasan'), 'cancellation_policy_not_configured');
  perform t.logout();
  perform public.provision_set_policy('cancellation_enabled', 'true');

  -- Daftar customer kosong: customer ditolak not_configured, admin tetap bisa.
  perform public.provision_set_policy('cancellation_allowed_statuses', '');
  perform t.login(cA);
  perform t.expect_err('cancel: daftar customer kosong -> customer ditolak', format(v, 'cancelled', 'alasan'), 'cancellation_policy_not_configured');
  perform t.logout();
  perform t.status_as(adm, o, 'cancelled', 'admin menutup');
  perform t.ok('cancel: daftar customer kosong tidak menghalangi admin',
    (select order_status from public.orders where id = o) = 'cancelled');
  perform public.provision_set_policy('cancellation_allowed_statuses', 'pending_seller');

  -- Validasi kunci seller baru di provision_set_policy.
  perform t.expect_err('kebijakan: cancellation_allowed_statuses_seller dengan status terminal ditolak',
    $q$select public.provision_set_policy('cancellation_allowed_statuses_seller', 'delivered')$q$, 'invalid_policy_value');
  perform public.provision_set_policy('cancellation_allowed_statuses_seller', 'pending_seller,accepted,preparing,ready_for_pickup');
  perform t.ok('kebijakan: cancellation_allowed_statuses_seller menerima daftar valid',
    (select value from public.ops_policy where key = 'cancellation_allowed_statuses_seller') = 'pending_seller,accepted,preparing,ready_for_pickup');
  perform public.provision_set_policy('cancellation_allowed_statuses_seller', 'pending_seller,accepted,preparing');
end $$;

rollback;
