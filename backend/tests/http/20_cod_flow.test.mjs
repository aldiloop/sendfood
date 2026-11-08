// Alur COD end-to-end lewat GoTrue + PostgREST asli dengan akun terpisah per peran.
import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { rest, rpc, sql, count, world, orderArgs, expectOk, expectError, FIX, run } from './lib/client.mjs';

let w, order, args;
before(async () => { w = await world(); });

test('katalog anon: list_stores/search_products menampilkan data nyata toko aktif (jarak, ongkir, harga)', async () => {
  const ls = await rpc('list_stores', { p_latitude: FIX.nearLat, p_longitude: FIX.nearLon, p_sort: 'nearest', p_limit: 50 });
  expectOk(ls, 'list_stores anon');
  const a = ls.body.find((s) => s.id === w.storeA.id);
  assert.ok(a, 'toko A tampil');
  assert.equal(Number(a.delivery_fee), FIX.fee);
  assert.equal(a.within_service_radius, true);
  assert.ok(a.distance_km > 1 && a.distance_km < 2, `distance ${a.distance_km}`);
  assert.deepEqual(Object.keys(a).sort(), ['address', 'delivery_fee', 'description', 'distance_km', 'id', 'image_url', 'latitude',
    'longitude', 'name', 'opening_hours', 'phone', 'service_radius_km', 'within_service_radius'].sort());
  const sp = await rpc('search_products', { p_store_id: w.storeA.id, p_sort: 'cheapest' });
  expectOk(sp, 'search_products anon');
  assert.deepEqual(sp.body.map((p) => p.id), [w.pA2.id, w.pA1.id], 'termurah dulu; produk habis tidak tampil');
  assert.deepEqual(Object.keys(sp.body[0]).sort(), ['delivery_fee', 'description', 'distance_km', 'id', 'image_url', 'name',
    'price', 'service_radius_km', 'store_id', 'store_name', 'within_service_radius'].sort());
  expectError(await rpc('search_products', { p_sort: 'rating' }), { status: 400, message: 'invalid_sort' }, 'sort rating');
  expectError(await rpc('list_stores', { p_sort: 'nearest' }), { status: 400, message: 'location_required_for_sort' }, 'nearest tanpa lokasi');
  expectError(await rpc('list_stores', { p_limit: 500 }), { status: 400, message: 'invalid_pagination' }, 'limit');
});

test('create_order COD: harga/ongkir/total dihitung server, status pending_seller, pembayaran unpaid', async () => {
  args = orderArgs(w.storeA, [{ product_id: w.pA1.id, quantity: 2, price: 1 }, { product_id: w.pA2.id, quantity: 1 }]);
  const r = await rpc('create_order', args, w.customerA.token);
  expectOk(r, 'create_order');
  assert.equal(r.body.length, 1);
  order = r.body[0];
  assert.deepEqual(Object.keys(order).sort(), ['delivery_fee', 'order_code', 'order_id', 'order_status', 'payment_method',
    'payment_status', 'subtotal', 'total'].sort());
  assert.equal(Number(order.subtotal), 25000, 'harga klien (price:1) diabaikan');
  assert.equal(Number(order.delivery_fee), FIX.fee);
  assert.equal(Number(order.total), 25000 + FIX.fee);
  assert.equal(order.order_status, 'pending_seller');
  assert.equal(order.payment_method, 'cod');
  assert.equal(order.payment_status, 'unpaid');
  assert.equal(count('public.order_items', `order_id='${order.order_id}'`), 2);
  assert.equal(sql(`select string_agg(product_name_snapshot||':'||unit_price_snapshot||'x'||quantity||'='||line_total, ',' order by unit_price_snapshot)
    from public.order_items where order_id='${order.order_id}'`), `Teh ${run}:5000.00x1=5000.00,Nasi ${run}:10000.00x2=20000.00`);
});

test('idempotency: kirim ulang key yang sama mengembalikan order yang sama; payload beda -> konflik', async () => {
  const again = await rpc('create_order', args, w.customerA.token);
  expectOk(again, 'replay');
  assert.equal(again.body[0].order_id, order.order_id);
  assert.equal(count('public.orders', `customer_id='${w.customerA.id}'`), 1);
  const conflict = await rpc('create_order', { ...args, p_delivery_note: 'beda' }, w.customerA.token);
  expectError(conflict, { status: 400, message: 'idempotency_key_conflict' }, 'konflik');
  // Key yang sama milik customer lain tidak bocor/terpakai bersama.
  const otherCust = await rpc('create_order', args, w.customerB.token);
  expectOk(otherCust, 'customer B key sama');
  assert.notEqual(otherCust.body[0].order_id, order.order_id);
});

test('snapshot: perubahan harga produk setelah order tidak mengubah item/total order', async () => {
  expectOk(await rest('PATCH', `/products?id=eq.${w.pA1.id}`, { token: w.sellerA.token, body: { price: 99999 } }), 'ubah harga', [204]);
  assert.equal(sql(`select unit_price_snapshot from public.order_items where order_id='${order.order_id}' and product_id='${w.pA1.id}'`), '10000.00');
  assert.equal(sql(`select total from public.orders where id='${order.order_id}'`), `${(25000 + FIX.fee).toFixed(2)}`);
  expectOk(await rest('PATCH', `/products?id=eq.${w.pA1.id}`, { token: w.sellerA.token, body: { price: 10000 } }), 'kembalikan', [204]);
});

const st = (o, s, token, note) => rpc('change_order_status', { p_order_id: o, p_new_status: s, p_note: note ?? null }, token);

test('lifecycle: seller accepted -> preparing -> ready; admin assign; driver picked_up -> delivered; customer completed', async () => {
  const id = order.order_id;
  expectError(await st(id, 'preparing', w.sellerA.token), { status: 400, message: 'status_transition_not_allowed' }, 'skip accepted');
  expectError(await st(id, 'accepted', w.sellerB.token), { status: 400, message: 'status_transition_not_allowed' }, 'seller lain');
  expectError(await st(id, 'accepted', w.customerA.token), { status: 400, message: 'status_transition_not_allowed' }, 'customer accept');
  const acc = await st(id, 'accepted', w.sellerA.token);
  expectOk(acc, 'accepted');
  assert.equal(acc.body, 'accepted', 'RPC mengembalikan skalar status baru');
  expectOk(await st(id, 'preparing', w.sellerA.token), 'preparing');
  expectOk(await st(id, 'ready_for_pickup', w.sellerA.token), 'ready');
  expectError(await st(id, 'picked_up', w.driverA.token), { status: 400, message: 'status_transition_not_allowed' }, 'driver belum ditugaskan');
  expectError(await rpc('assign_order_driver', { p_order_id: id, p_driver_id: w.driverA.id }, w.sellerA.token),
    { status: 400, message: 'admin_role_required' }, 'seller assign');
  expectError(await rpc('assign_order_driver', { p_order_id: id, p_driver_id: w.driverA.id }, w.driverA.token),
    { status: 400, message: 'admin_role_required' }, 'driver self-assign');
  expectError(await rpc('assign_order_driver', { p_order_id: id, p_driver_id: w.customerB.id }, w.admin.token),
    { status: 400, message: 'driver_profile_required' }, 'assign non-driver');
  const as = await rpc('assign_order_driver', { p_order_id: id, p_driver_id: w.driverA.id }, w.admin.token);
  expectOk(as, 'assign');
  assert.equal(as.body, w.driverA.id, 'RPC mengembalikan uuid driver');
  expectError(await st(id, 'picked_up', w.driverB.token), { status: 400, message: 'status_transition_not_allowed' }, 'driver lain');
  expectOk(await st(id, 'picked_up', w.driverA.token), 'picked_up');
  expectError(await rpc('assign_order_driver', { p_order_id: id, p_driver_id: w.driverB.id }, w.admin.token),
    { status: 400, message: 'order_not_assignable' }, 'reassign setelah pickup');
  expectOk(await st(id, 'delivered', w.driverA.token), 'delivered');
  expectError(await st(id, 'completed', w.driverA.token), { status: 400, message: 'status_transition_not_allowed' }, 'driver complete');
  expectError(await st(id, 'completed', w.customerB.token), { status: 400, message: 'status_transition_not_allowed' }, 'customer lain');
  expectOk(await st(id, 'completed', w.customerA.token), 'completed oleh customer (completion_actor default)');
  expectError(await st(id, 'completed', w.customerA.token), { status: 400, message: 'status_transition_not_allowed' }, 'ulang');
});

test('history: setiap transisi dan assignment tercatat dengan aktor yang benar', () => {
  const rows = sql(`select string_agg(coalesce(old_status::text,'-')||'>'||new_status||'@'||
      case changed_by when '${w.sellerA.id}' then 'seller' when '${w.admin.id}' then 'admin'
        when '${w.driverA.id}' then 'driver' when '${w.customerA.id}' then 'customer' else coalesce(changed_by::text,'null') end,
      ' ' order by created_at, id) from public.order_status_history where order_id='${order.order_id}'`);
  assert.equal(rows, '->pending_seller@customer pending_seller>accepted@seller accepted>preparing@seller '
    + 'preparing>ready_for_pickup@seller ready_for_pickup>ready_for_pickup@admin ready_for_pickup>picked_up@driver '
    + 'picked_up>delivered@driver delivered>completed@customer');
  assert.equal(count('public.admin_audit_log', `action='assign_order_driver' and target_id='${order.order_id}'`), 1);
});

test('pembayaran: completed TIDAK berarti lunas; record_cod_collection ditolak sampai kebijakan dikonfigurasi', async () => {
  assert.equal(sql(`select payment_status from public.orders where id='${order.order_id}'`), 'unpaid');
  for (const who of [w.driverA, w.admin]) {
    expectError(await rpc('record_cod_collection', { p_order_id: order.order_id }, who.token),
      { status: 400, message: 'cod_collection_policy_not_configured' }, `cod ${who.label}`);
  }
  assert.equal(sql(`select payment_status from public.orders where id='${order.order_id}'`), 'unpaid');
});

test('list_my_orders: tiap peran melihat order miliknya dengan items JSON snapshot', async () => {
  const shape = (o) => Object.keys(o).sort();
  const cols = ['created_at', 'customer_id', 'delivery_address', 'delivery_fee', 'delivery_latitude', 'delivery_longitude',
    'delivery_note', 'driver_id', 'items', 'order_code', 'order_id', 'order_status', 'payment_method', 'payment_status',
    'store_id', 'store_name', 'subtotal', 'total'].sort();
  for (const [who, expected] of [[w.customerA, 1], [w.sellerA, 2], [w.driverA, 1], [w.customerB, 1], [w.sellerB, 0], [w.driverB, 0]]) {
    const r = await rpc('list_my_orders', {}, who.token);
    expectOk(r, `list_my_orders ${who.label}`);
    assert.equal(r.body.length, expected, `${who.label} jumlah order`);
    if (r.body.length) assert.deepEqual(shape(r.body[0]), cols);
  }
  const mine = (await rpc('list_my_orders', { p_status: 'completed' }, w.customerA.token)).body;
  assert.equal(mine.length, 1);
  assert.deepEqual(Object.keys(mine[0].items[0]).sort(), ['line_total', 'name', 'product_id', 'quantity', 'unit_price']);
  assert.equal(mine[0].items.reduce((t, i) => t + Number(i.line_total), 0), 25000);
  const adm = await rpc('list_my_orders', { p_limit: 100 }, w.admin.token);
  assert.ok(adm.body.length >= 2, 'admin melihat semua order');
  expectError(await rpc('list_my_orders', {}), { status: [401, 403] }, 'anon list_my_orders');
});

test('pengelolaan produk seller: tambah, ubah, nonaktifkan, hapus milik sendiri; admin menonaktifkan produk', async () => {
  const p = (await rest('POST', '/products', { token: w.sellerA.token, headers: { Prefer: 'return=representation' },
    body: { store_id: w.storeA.id, name: 'Produk Sementara', price: 3000 } }));
  expectOk(p, 'insert', [201]);
  const id = p.body[0].id;
  expectOk(await rest('PATCH', `/products?id=eq.${id}`, { token: w.sellerA.token, body: { is_available: false, description: 'x' } }), 'patch', [204]);
  const adm = await rpc('admin_set_product_available', { p_product_id: id, p_available: true }, w.admin.token);
  expectOk(adm, 'admin available');
  assert.equal(adm.body, true);
  expectError(await rpc('admin_set_product_available', { p_product_id: id, p_available: false }, w.sellerA.token),
    { status: 400, message: 'admin_role_required' }, 'seller pakai admin rpc');
  expectOk(await rest('DELETE', `/products?id=eq.${id}`, { token: w.sellerA.token }), 'delete', [204]);
  assert.equal(count('public.products', `id='${id}'`), 0);
});

test('alamat tersimpan: customer CRUD milik sendiri', async () => {
  const ins = await rest('POST', '/customer_addresses', { token: w.customerA.token, headers: { Prefer: 'return=representation' },
    body: { label: 'Rumah', address: 'Jl. Uji 2', latitude: FIX.nearLat, longitude: FIX.nearLon, note: 'pagar hijau' } });
  expectOk(ins, 'insert alamat', [201]);
  assert.equal(ins.body[0].customer_id, w.customerA.id, 'customer_id dari auth.uid()');
  const id = ins.body[0].id;
  expectOk(await rest('PATCH', `/customer_addresses?id=eq.${id}`, { token: w.customerA.token, body: { note: 'pagar biru' } }), 'patch', [204]);
  const list = await rest('GET', '/customer_addresses?select=id,label,note', { token: w.customerA.token });
  assert.deepEqual(list.body, [{ id, label: 'Rumah', note: 'pagar biru' }]);
  expectOk(await rest('DELETE', `/customer_addresses?id=eq.${id}`, { token: w.customerA.token }), 'delete', [204]);
});
