// Matriks RLS/grant lewat JWT GoTrue asli + PostgREST asli: anon, customer, seller, driver, admin;
// milik sendiri vs milik orang lain; baca dan tulis langsung.
import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { rest, rpc, sql, world, orderArgs, expectOk, expectError, makeStore, makeProduct } from './lib/client.mjs';

let w, oA, oB, inactive, hiddenProduct, addrA;
const ids = (r) => (r.body ?? []).map((x) => x.id).sort();
const get = (path, who) => rest('GET', path, { token: who?.token });

before(async () => {
  w = await world();
  oA = (await rpc('create_order', orderArgs(w.storeA, [{ product_id: w.pA1.id, quantity: 1 }]), w.customerA.token)).body[0].order_id;
  oB = (await rpc('create_order', orderArgs(w.storeB, [{ product_id: w.pB1.id, quantity: 1 }]), w.customerB.token)).body[0].order_id;
  expectOk(await rpc('change_order_status', { p_order_id: oA, p_new_status: 'accepted' }, w.sellerA.token), 'accept oA');
  expectOk(await rpc('assign_order_driver', { p_order_id: oA, p_driver_id: w.driverA.id }, w.admin.token), 'assign oA');
  inactive = await makeStore(w.sellerA, w.admin, 'Toko Tersembunyi', { configure: false, activate: false });
  hiddenProduct = w.pAoff;
  addrA = (await rest('POST', '/customer_addresses', { token: w.customerA.token, headers: { Prefer: 'return=representation' },
    body: { label: 'Rumah A', address: 'Jl. Rahasia A' } })).body[0];
});

test('anon: hanya toko aktif dan produk tersedia; tidak ada data pengguna/pesanan/kebijakan', async () => {
  const stores = ids(await get(`/stores?id=in.(${w.storeA.id},${inactive.id})&select=id`));
  assert.deepEqual(stores, [w.storeA.id]);
  assert.deepEqual(ids(await get(`/products?id=in.(${w.pA1.id},${hiddenProduct.id})&select=id`)), [w.pA1.id]);
  for (const t of ['profiles', 'orders', 'order_items', 'order_status_history', 'customer_addresses', 'ops_policy', 'admin_audit_log']) {
    const r = await get(`/${t}?select=*`);
    assert.ok(r.status === 401 || (r.status === 200 && r.body.length === 0), `anon ${t}: ${r.status} ${r.body?.length}`);
  }
  for (const [path, body] of [['/stores', { owner_id: w.sellerA.id, name: 'x', address: 'y' }], ['/products', { store_id: w.storeA.id, name: 'x', price: 1 }],
    ['/customer_addresses', { label: 'x', address: 'y' }]]) {
    expectError(await rest('POST', path, { body }), { status: 401 }, `anon insert ${path}`);
  }
  expectError(await rest('PATCH', `/products?id=eq.${w.pA1.id}`, { body: { price: 1 } }), { status: 401 }, 'anon patch product');
});

test('customer: hanya order/item/history/alamat miliknya', async () => {
  const A = w.customerA, B = w.customerB;
  assert.deepEqual(ids(await get(`/orders?select=id`, A)), [oA]);
  assert.deepEqual(ids(await get(`/orders?select=id`, B)), [oB]);
  assert.deepEqual((await get(`/order_items?order_id=eq.${oB}&select=id`, A)).body, []);
  assert.deepEqual((await get(`/order_status_history?order_id=eq.${oB}&select=id`, A)).body, []);
  assert.equal((await get(`/order_status_history?order_id=eq.${oA}&select=id`, A)).body.length, 3);
  assert.deepEqual(ids(await get(`/customer_addresses?select=id`, A)), [addrA.id]);
  assert.deepEqual((await get(`/customer_addresses?select=id`, B)).body, []);
  // Ubah/hapus alamat orang lain: RLS menyaring baris -> 0 baris tersentuh.
  const p = await rest('PATCH', `/customer_addresses?id=eq.${addrA.id}`, { token: B.token, headers: { Prefer: 'return=representation' }, body: { note: 'bajak' } });
  assert.deepEqual(p.body, []);
  const d = await rest('DELETE', `/customer_addresses?id=eq.${addrA.id}`, { token: B.token, headers: { Prefer: 'return=representation' } });
  assert.deepEqual(d.body, []);
  assert.equal(sql(`select count(*) from public.customer_addresses where id='${addrA.id}' and note is null`), '1');
  // Tidak bisa memalsukan customer_id alamat (kolom tidak di-grant).
  expectError(await rest('POST', '/customer_addresses', { token: B.token, body: { customer_id: A.id, label: 'x', address: 'y' } }),
    { status: [401, 403] }, 'customer_id palsu');
  // Profil: hanya diri sendiri.
  assert.deepEqual(ids(await get(`/profiles?select=id`, A)), [A.id]);
  // Customer tidak bisa membuat toko/produk.
  expectError(await rest('POST', '/stores', { token: A.token, body: { owner_id: A.id, name: 'x', address: 'y' } }), { status: [401, 403] }, 'cust store');
  expectError(await rest('POST', '/products', { token: A.token, body: { store_id: w.storeA.id, name: 'x', price: 1 } }), { status: [401, 403] }, 'cust product');
  // Customer tidak bisa mengubah status order orang lain / memakai RPC seller/admin.
  expectError(await rpc('change_order_status', { p_order_id: oB, p_new_status: 'accepted' }, A.token), { status: 400, message: 'status_transition_not_allowed' }, 'cust status');
});

test('seller: order/toko/produk miliknya saja; field operasional terkunci', async () => {
  const S = w.sellerA;
  assert.deepEqual(ids(await get(`/orders?select=id`, S)), [oA]);
  assert.deepEqual((await get(`/orders?id=eq.${oB}&select=id`, w.sellerA)).body, []);
  assert.deepEqual(ids(await get(`/orders?select=id`, w.sellerB)), [oB]);
  assert.deepEqual((await get('/customer_addresses?select=id', S)).body, [], 'seller tidak lihat alamat tersimpan customer');
  assert.deepEqual(ids(await get(`/stores?id=eq.${inactive.id}&select=id`, S)), [inactive.id], 'pemilik melihat toko nonaktif sendiri');
  assert.deepEqual((await get(`/stores?id=eq.${inactive.id}&select=id`, w.sellerB)).body, [], 'seller lain tidak');
  assert.deepEqual(ids(await get(`/profiles?select=id`, S)), [S.id]);
  // Ubah deskripsi toko sendiri: boleh.
  expectOk(await rest('PATCH', `/stores?id=eq.${w.storeA.id}`, { token: S.token, body: { description: 'baru' } }), 'patch desc', [204]);
  // Field operasional: ditolak trigger/grant.
  for (const body of [{ is_active: false }, { delivery_fee: 0 }, { service_radius_km: 999 }, { owner_id: w.sellerB.id }, { latitude: -7 }]) {
    const r = await rest('PATCH', `/stores?id=eq.${w.storeA.id}`, { token: S.token, body });
    assert.ok([400, 401, 403].includes(r.status), `seller ${JSON.stringify(body)} -> ${r.status} ${r.body?.message}`);
  }
  assert.equal(sql(`select is_active||'/'||delivery_fee||'/'||service_radius_km||'/'||owner_id from public.stores where id='${w.storeA.id}'`),
    `true/8000.00/5.00/${S.id}`);
  // Toko/produk seller lain.
  const p = await rest('PATCH', `/stores?id=eq.${w.storeB.id}`, { token: S.token, headers: { Prefer: 'return=representation' }, body: { description: 'bajak' } });
  assert.deepEqual(p.body, []);
  expectError(await rest('POST', '/products', { token: S.token, body: { store_id: w.storeB.id, name: 'x', price: 1 } }), { status: [401, 403] }, 'produk toko lain');
  const pp = await rest('PATCH', `/products?id=eq.${w.pB1.id}`, { token: S.token, headers: { Prefer: 'return=representation' }, body: { price: 1 } });
  assert.deepEqual(pp.body, []);
  const dp = await rest('DELETE', `/products?id=eq.${w.pB1.id}`, { token: S.token, headers: { Prefer: 'return=representation' } });
  assert.deepEqual(dp.body, []);
  assert.equal(sql(`select price from public.products where id='${w.pB1.id}'`), '12000.00');
  // Pindahkan produk ke toko lain: kolom store_id tidak di-grant untuk update.
  expectError(await rest('PATCH', `/products?id=eq.${w.pA1.id}`, { token: S.token, body: { store_id: w.storeB.id } }), { status: [401, 403] }, 'pindah toko');
  // Seller tidak bisa membuat toko atas nama orang lain.
  expectError(await rest('POST', '/stores', { token: S.token, body: { owner_id: w.sellerB.id, name: 'x', address: 'y' } }), { status: [401, 403] }, 'owner palsu');
  // Harga NaN ditolak.
  expectError(await rest('PATCH', `/products?id=eq.${w.pA1.id}`, { token: S.token, body: { price: 'NaN' } }), { status: 400, code: '23514' }, 'harga NaN');
  // Seller tidak bisa mengaktifkan toko sendiri lewat RPC admin.
  expectError(await rpc('admin_set_store_active', { p_store_id: inactive.id, p_active: true }, S.token), { status: 400, message: 'admin_role_required' }, 'self activate');
});

test('driver: hanya order yang ditugaskan; tidak bisa mengubah order lain', async () => {
  assert.deepEqual(ids(await get(`/orders?select=id`, w.driverA)), [oA]);
  assert.deepEqual((await get(`/orders?select=id`, w.driverB)).body, []);
  assert.equal((await get(`/order_items?order_id=eq.${oA}&select=id`, w.driverA)).body.length, 1);
  assert.deepEqual((await get(`/order_items?order_id=eq.${oB}&select=id`, w.driverA)).body, []);
  assert.deepEqual((await get('/customer_addresses?select=id', w.driverA)).body, []);
  assert.deepEqual(ids(await get(`/profiles?select=id`, w.driverA)), [w.driverA.id]);
  expectError(await rpc('change_order_status', { p_order_id: oB, p_new_status: 'accepted' }, w.driverA.token), { status: 400, message: 'status_transition_not_allowed' }, 'driver status oB');
  expectError(await rest('POST', '/products', { token: w.driverA.token, body: { store_id: w.storeA.id, name: 'x', price: 1 } }), { status: [401, 403] }, 'driver product');
});

test('admin: membaca semua order/profil/audit; tetap tidak bisa tulis langsung order atau membaca ops_policy mentah', async () => {
  const all = ids(await get(`/orders?id=in.(${oA},${oB})&select=id`, w.admin));
  assert.deepEqual(all, [oA, oB].sort());
  assert.ok((await get(`/profiles?select=id`, w.admin)).body.length >= 7);
  assert.ok((await get(`/admin_audit_log?select=id,action`, w.admin)).body.some((r) => r.action === 'assign_order_driver'));
  for (const who of [w.customerA, w.sellerA, w.driverA]) {
    assert.deepEqual((await get('/admin_audit_log?select=id', who)).body, [], `${who.label} audit log`);
  }
  const op = await get('/ops_policy?select=*', w.admin);
  assert.ok([401, 403].includes(op.status), `ops_policy langsung: ${op.status}`);
  const r = await rest('PATCH', `/orders?id=eq.${oA}`, { token: w.admin.token, body: { payment_status: 'verified' } });
  assert.ok([401, 403].includes(r.status) || /direct_write_forbidden/.test(r.body?.message), `admin patch ${r.status}`);
  const pr = await rest('PATCH', `/profiles?id=eq.${w.customerA.id}`, { token: w.admin.token, body: { role: 'admin' } });
  assert.ok([401, 403].includes(pr.status), `admin patch role ${pr.status}`);
  assert.equal(sql(`select role from public.profiles where id='${w.customerA.id}'`), 'customer');
});
