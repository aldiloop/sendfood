// Checkout negatif, rollback, kebijakan fail-closed dan konkurensi lewat PostgREST asli.
import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { rest, rpc, sql, world, orderArgs, expectOk, expectError, FIX, key, makeStore, makeProduct } from './lib/client.mjs';

let w;
before(async () => { w = await world(); });

const totals = () => sql(`select (select count(*) from public.orders)||'/'||(select count(*) from public.order_items)||'/'||
  (select count(*) from public.order_status_history)`);

test('checkout yang ditolak tidak meninggalkan order/item/history parsial (hitung total tabel, bukan JOIN)', async () => {
  const before = totals();
  const C = w.customerA.token;
  const cases = [
    ['beda toko', orderArgs(w.storeA, [{ product_id: w.pA1.id, quantity: 1 }, { product_id: w.pB1.id, quantity: 1 }]), 'product_unavailable_or_wrong_store'],
    ['produk tidak tersedia', orderArgs(w.storeA, [{ product_id: w.pAoff.id, quantity: 1 }]), 'product_unavailable_or_wrong_store'],
    ['produk tidak ada', orderArgs(w.storeA, [{ product_id: '00000000-0000-0000-0000-000000000000', quantity: 1 }]), 'product_unavailable_or_wrong_store'],
    ['quantity 0', orderArgs(w.storeA, [{ product_id: w.pA1.id, quantity: 0 }]), 'invalid_order_item'],
    ['quantity 100', orderArgs(w.storeA, [{ product_id: w.pA1.id, quantity: 100 }]), 'invalid_order_item'],
    ['quantity teks', orderArgs(w.storeA, [{ product_id: w.pA1.id, quantity: 'dua' }]), 'invalid_order_item'],
    ['produk ganda', orderArgs(w.storeA, [{ product_id: w.pA1.id, quantity: 1 }, { product_id: w.pA1.id, quantity: 2 }]), 'duplicate_product_in_items'],
    ['items kosong', orderArgs(w.storeA, []), 'item_count_out_of_range'],
    ['items bukan array', orderArgs(w.storeA, { product_id: w.pA1.id }), 'items_must_be_array'],
    ['di luar radius', orderArgs(w.storeA, [{ product_id: w.pA1.id, quantity: 1 }], { p_delivery_latitude: FIX.farLat, p_delivery_longitude: FIX.farLon }), 'outside_store_service_radius'],
    ['latitude > 90', orderArgs(w.storeA, [{ product_id: w.pA1.id, quantity: 1 }], { p_delivery_latitude: 91 }), 'valid_delivery_coordinates_required'],
    ['longitude null', orderArgs(w.storeA, [{ product_id: w.pA1.id, quantity: 1 }], { p_delivery_longitude: null }), 'valid_delivery_coordinates_required'],
    ['latitude NaN', orderArgs(w.storeA, [{ product_id: w.pA1.id, quantity: 1 }], { p_delivery_latitude: 'NaN' }), 'valid_delivery_coordinates_required'],
    ['alamat kosong', orderArgs(w.storeA, [{ product_id: w.pA1.id, quantity: 1 }], { p_delivery_address: '  ' }), 'delivery_address_required'],
    ['catatan > 1000', orderArgs(w.storeA, [{ product_id: w.pA1.id, quantity: 1 }], { p_delivery_note: 'x'.repeat(1001) }), 'delivery_note_too_long'],
    ['transfer manual', orderArgs(w.storeA, [{ product_id: w.pA1.id, quantity: 1 }], { p_payment_method: 'manual_transfer' }), 'manual_transfer_not_configured'],
    ['key format', orderArgs(w.storeA, [{ product_id: w.pA1.id, quantity: 1 }], { p_idempotency_key: 'a b' }), 'invalid_idempotency_key'],
  ];
  for (const [label, a, msg] of cases) {
    expectError(await rpc('create_order', a, C), { status: 400, message: msg, code: 'P0001' }, label);
  }
  assert.equal(totals(), before, 'tidak ada baris tersisa dari checkout yang ditolak');
});

test('checkout: toko nonaktif / belum dikonfigurasi ditolak', async () => {
  const unconf = await makeStore(w.sellerA, w.admin, 'Toko Belum Dikonfigurasi', { configure: false, activate: true });
  const p = await makeProduct(w.sellerA, unconf.id, 'Produk X', 1000);
  expectError(await rpc('create_order', orderArgs(unconf, [{ product_id: p.id, quantity: 1 }]), w.customerA.token),
    { status: 400, message: 'store_delivery_not_configured' }, 'belum dikonfigurasi');
  const inactive = await makeStore(w.sellerA, w.admin, 'Toko Nonaktif', { configure: true, activate: false });
  const p2 = await makeProduct(w.sellerA, inactive.id, 'Produk Y', 1000);
  expectError(await rpc('create_order', orderArgs(inactive, [{ product_id: p2.id, quantity: 1 }]), w.customerA.token),
    { status: 400, message: 'store_not_available' }, 'nonaktif');
});

test('checkout: hanya customer; anon dan peran lain ditolak', async () => {
  const a = orderArgs(w.storeA, [{ product_id: w.pA1.id, quantity: 1 }]);
  expectError(await rpc('create_order', a), { status: [401, 403] }, 'anon');
  for (const who of [w.sellerA, w.driverA, w.admin]) {
    expectError(await rpc('create_order', a, who.token), { status: 400, message: 'customer_role_required' }, who.label);
  }
});

test('tulis langsung ke orders/order_items/order_status_history ditolak untuk semua peran', async () => {
  const ok = await rpc('create_order', orderArgs(w.storeA, [{ product_id: w.pA1.id, quantity: 1 }]), w.customerA.token);
  const oid = ok.body[0].order_id;
  const before = totals();
  for (const who of [w.customerA, w.sellerA, w.driverA, w.admin]) {
    const T = who.token;
    const attempts = [
      rest('POST', '/orders', { token: T, body: { customer_id: who.id, store_id: w.storeA.id, delivery_address: 'x', subtotal: 1, delivery_fee: 0, total: 1 } }),
      rest('PATCH', `/orders?id=eq.${oid}`, { token: T, body: { total: 1, payment_status: 'verified' } }),
      rest('PATCH', `/orders?id=eq.${oid}`, { token: T, body: { order_status: 'completed' } }),
      rest('DELETE', `/orders?id=eq.${oid}`, { token: T }),
      rest('POST', '/order_items', { token: T, body: { order_id: oid, product_id: w.pA1.id, product_name_snapshot: 'x', unit_price_snapshot: 0, quantity: 1, line_total: 0 } }),
      rest('PATCH', `/order_items?order_id=eq.${oid}`, { token: T, body: { unit_price_snapshot: 0 } }),
      rest('POST', '/order_status_history', { token: T, body: { order_id: oid, new_status: 'completed' } }),
      rest('DELETE', `/order_status_history?order_id=eq.${oid}`, { token: T }),
    ];
    for (const r of await Promise.all(attempts)) {
      assert.ok([401, 403].includes(r.status) || (r.status === 400 && /direct_write_forbidden/.test(r.body?.message)),
        `${who.label}: ${r.status} ${r.body?.code} ${r.body?.message}`);
    }
  }
  assert.equal(totals(), before);
  assert.equal(sql(`select payment_status||'/'||order_status||'/'||total from public.orders where id='${oid}'`), `unpaid/pending_seller/${(10000 + FIX.orderFee).toFixed(2)}`);
});

test('kebijakan fail-closed: pembatalan dan pencatatan COD ditolak; delivered tidak menjadi lunas', async () => {
  // Seed migrasi pembatalan per aktor mengaktifkan cancellation_enabled; matikan dulu
  // agar cek fail-closed tetap berlaku, pulihkan di akhir tes.
  sql(`select public.provision_set_policy('cancellation_enabled', 'false')`);
  const r = await rpc('create_order', orderArgs(w.storeA, [{ product_id: w.pA2.id, quantity: 1 }]), w.customerA.token);
  const oid = r.body[0].order_id;
  for (const who of [w.customerA, w.sellerA, w.admin]) {
    expectError(await rpc('change_order_status', { p_order_id: oid, p_new_status: 'cancelled', p_note: 'alasan' }, who.token),
      { status: 400, message: 'cancellation_policy_not_configured' }, `batal ${who.label}`);
  }
  expectError(await rpc('change_order_status', { p_order_id: oid, p_new_status: 'rejected' }, w.sellerA.token),
    { status: 400, message: 'rejection_reason_required' }, 'reject tanpa alasan');
  const pol = await rpc('admin_get_policies', {}, w.admin.token);
  expectOk(pol, 'admin_get_policies');
  const map = Object.fromEntries(pol.body.map((p) => [p.key, p.value]));
  assert.equal(map.cancellation_enabled, 'false');
  assert.equal(map.manual_transfer_enabled, 'false');
  assert.equal(map.cod_collection_recording_enabled, 'false');
  expectError(await rpc('admin_get_policies', {}, w.customerA.token), { status: 400, message: 'admin_role_required' }, 'policies customer');
  assert.equal(sql(`select payment_status from public.orders where id='${oid}'`), 'unpaid');
  sql(`select public.provision_set_policy('cancellation_enabled', 'true')`);
});

test('konkurensi: 12 request paralel dengan idempotency key sama -> tepat 1 order', async () => {
  const a = orderArgs(w.storeA, [{ product_id: w.pA1.id, quantity: 1 }], { p_idempotency_key: key('par') });
  const before = Number(sql(`select count(*) from public.orders where customer_id='${w.customerB.id}'`));
  const res = await Promise.all(Array.from({ length: 12 }, () => rpc('create_order', a, w.customerB.token)));
  res.forEach((r, i) => expectOk(r, `paralel #${i}`));
  const ids = new Set(res.map((r) => r.body[0].order_id));
  assert.equal(ids.size, 1, 'semua respons merujuk order yang sama');
  assert.equal(Number(sql(`select count(*) from public.orders where customer_id='${w.customerB.id}'`)), before + 1);
  assert.equal(Number(sql(`select count(*) from public.order_items where order_id='${[...ids][0]}'`)), 1);
  assert.equal(Number(sql(`select count(*) from public.order_status_history where order_id='${[...ids][0]}'`)), 1);
});

test('konkurensi: 8 key berbeda paralel -> 8 order konsisten (subtotal/total benar, tanpa item yatim)', async () => {
  const res = await Promise.all(Array.from({ length: 8 }, () =>
    rpc('create_order', orderArgs(w.storeA, [{ product_id: w.pA2.id, quantity: 3 }]), w.customerB.token)));
  res.forEach((r, i) => expectOk(r, `beda key #${i}`));
  assert.equal(new Set(res.map((r) => r.body[0].order_id)).size, 8);
  assert.equal(sql(`select count(*) from public.order_items i left join public.orders o on o.id=i.order_id where o.id is null`), '0');
  assert.equal(sql(`select count(*) from public.orders where subtotal <> (select sum(line_total) from public.order_items i where i.order_id = orders.id)`), '0');
});

test('konkurensi: perubahan harga bersamaan checkout -> snapshot konsisten dengan salah satu harga, tidak campur', async () => {
  const p = await makeProduct(w.sellerA, w.storeA.id, 'Harga Berubah', 1000);
  const orders = Array.from({ length: 6 }, () =>
    rpc('create_order', orderArgs(w.storeA, [{ product_id: p.id, quantity: 2 }]), w.customerA.token));
  const upd = rest('PATCH', `/products?id=eq.${p.id}`, { token: w.sellerA.token, body: { price: 2000 } });
  const res = await Promise.all([...orders, upd]);
  res.slice(0, 6).forEach((r, i) => expectOk(r, `order #${i}`));
  const bad = sql(`select count(*) from public.order_items i join public.orders o on o.id=i.order_id
    where i.product_id='${p.id}' and (i.unit_price_snapshot not in (1000,2000) or i.line_total <> i.unit_price_snapshot*2
      or o.subtotal <> i.line_total)`);
  assert.equal(bad, '0');
});

test('konkurensi alamat lewat HTTP: 9 alamat + 2 POST paralel -> tepat 10, satu address_limit_reached', async () => {
  const C = w.customerB.token;
  for (let i = 0; i < 9; i++) {
    expectOk(await rest('POST', '/customer_addresses', { token: C, body: { label: `A${i}`, address: `Jl ${i}` } }), `alamat ${i}`, [201]);
  }
  const res = await Promise.all([0, 1].map((i) => rest('POST', '/customer_addresses', { token: C, body: { label: `P${i}`, address: 'Jl P' } })));
  const ok = res.filter((r) => r.status === 201).length;
  const lim = res.filter((r) => r.status === 400 && /address_limit_reached/.test(r.body?.message)).length;
  assert.equal(ok, 1, res.map((r) => `${r.status} ${r.body?.message}`).join(' | '));
  assert.equal(lim, 1);
  assert.equal(sql(`select count(*) from public.customer_addresses where customer_id='${w.customerB.id}'`), '10');
});

test('admin_set_store_delivery_config menolak NaN/negatif/nol dan tidak mengubah konfigurasi', async () => {
  const before = sql(`select delivery_fee||'/'||service_radius_km from public.stores where id='${w.storeA.id}'`);
  for (const [fee, radius] of [['NaN', 5], [8000, 'NaN'], [-1, 5], [8000, 0], [8000, -3]]) {
    expectError(await rpc('admin_set_store_delivery_config', { p_store_id: w.storeA.id, p_delivery_fee: fee, p_service_radius_km: radius }, w.admin.token),
      { status: 400, message: 'invalid_delivery_config' }, `config ${fee}/${radius}`);
  }
  expectError(await rpc('admin_set_store_delivery_config', { p_store_id: w.storeA.id, p_delivery_fee: 1, p_service_radius_km: 1 }, w.sellerA.token),
    { status: 400, message: 'admin_role_required' }, 'seller config');
  assert.equal(sql(`select delivery_fee||'/'||service_radius_km from public.stores where id='${w.storeA.id}'`), before);
  assert.equal(sql(`select count(*) from public.stores where delivery_fee = 'NaN' or service_radius_km = 'NaN'`), '0');
});
