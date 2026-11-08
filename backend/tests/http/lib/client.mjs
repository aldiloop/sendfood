// Klien HTTP untuk tes stack lokal: memanggil GoTrue dan PostgREST ASLI lewat fetch.
// Tidak ada mock. Token tidak pernah dicetak; pesan assert hanya memuat status/kode/pesan error.
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';

const need = (k) => {
  const v = process.env[k];
  if (!v) throw new Error(`env ${k} tidak ada: jalankan lewat backend/tests/stack/run_stack.sh`);
  return v;
};

export const cfg = {
  auth: need('SF_AUTH_URL'),
  rest: need('SF_REST_URL'),
  anonKey: need('SF_ANON_KEY'),
  serviceKey: need('SF_SERVICE_KEY'),
  jwtSecret: need('SF_JWT_SECRET'),
  psql: need('SF_PSQL'),
  db: need('SF_DB'),
};

for (const u of [cfg.auth, cfg.rest]) {
  const h = new URL(u).hostname;
  if (h !== '127.0.0.1' && h !== 'localhost') throw new Error(`target bukan lokal: ${h}`);
}

async function http(method, url, { token, body, headers = {}, apikey = cfg.anonKey, raw = false } = {}) {
  const h = { apikey, ...headers };
  if (token) h.Authorization = `Bearer ${token}`;
  let payload;
  if (body !== undefined && !raw) {
    h['Content-Type'] = h['Content-Type'] || 'application/json';
    payload = JSON.stringify(body);
  } else if (raw) {
    payload = body;
  }
  const res = await fetch(url, { method, headers: h, body: payload });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { json = null; }
  return { status: res.status, body: json, text, headers: res.headers };
}

// ---------------- PostgREST ----------------
export const rest = (method, path, opts = {}) => http(method, `${cfg.rest}${path}`, opts);
export const rpc = (name, args = {}, token, opts = {}) =>
  rest('POST', `/rpc/${name}`, { token, body: args, ...opts });
export const service = { rpc: (name, args = {}) => rpc(name, args, cfg.serviceKey, { apikey: cfg.serviceKey }) };

// ---------------- GoTrue ----------------
export const auth = {
  signUp: (email, password, data) => http('POST', `${cfg.auth}/signup`, { body: { email, password, data } }),
  signIn: (email, password) =>
    http('POST', `${cfg.auth}/token?grant_type=password`, { body: { email, password } }),
  refresh: (refresh_token) =>
    http('POST', `${cfg.auth}/token?grant_type=refresh_token`, { body: { refresh_token } }),
  user: (token) => http('GET', `${cfg.auth}/user`, { token }),
  update: (token, body) => http('PUT', `${cfg.auth}/user`, { token, body }),
  logout: (token, scope = 'global') => http('POST', `${cfg.auth}/logout?scope=${scope}`, { token }),
};

// ---------------- SQL tepercaya (superuser lokal, HANYA untuk assert jumlah baris) ----------------
export function sql(query) {
  return execFileSync(cfg.psql, ['-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1', '-d', cfg.db, '-c', query], {
    encoding: 'utf8', env: { ...process.env },
  }).trim();
}
export const count = (table, where = 'true') => Number(sql(`select count(*) from ${table} where ${where}`));

// ---------------- Assert helper ----------------
// Pesan assert tidak boleh memuat token: JWT dan refresh token disensor.
export const redact = (t) => String(t ?? '')
  .replace(/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*/g, '<JWT>')
  .replace(/"(refresh_token|access_token|provider_token)"\s*:\s*"[^"]*"/g, '"$1":"<REDACTED>"');
const describe = (res) => redact(`HTTP ${res.status} ${res.body?.code ?? ''} ${res.body?.message ?? res.body?.msg ?? res.text?.slice(0, 200)}`);
export function expectError(res, { status, message, code } = {}, label = '') {
  const info = `${label} -> ${describe(res)}`;
  if (status !== undefined) {
    if (Array.isArray(status)) assert.ok(status.includes(res.status), info);
    else assert.equal(res.status, status, info);
  } else {
    assert.ok(res.status >= 400, info);
  }
  if (message) assert.match(String(res.body?.message ?? res.body?.msg ?? res.text), message instanceof RegExp ? message : new RegExp(message), info);
  if (code) assert.equal(res.body?.code, code, info);
}
export function expectOk(res, label = '', statuses = [200, 201, 204]) {
  assert.ok(statuses.includes(res.status), `${label} -> ${describe(res)}`);
  return res.body;
}

// ---------------- Dunia uji: akun nyata per peran ----------------
const PASSWORD = 'Local-Only-Test-Pw-1'; // hanya untuk stack lokal sekali pakai
export const run = randomUUID().slice(0, 8);

export async function makeUser(label, role = 'customer', metadata = {}) {
  const email = `${label}.${run}@sendfood.test`;
  const su = await auth.signUp(email, PASSWORD, { full_name: `Uji ${label}`, ...metadata });
  expectOk(su, `signup ${label}`, [200]);
  const id = su.body.user?.id ?? su.body.id;
  assert.ok(id, `signup ${label}: tidak ada user id`);
  if (role !== 'customer') {
    const pr = await service.rpc('provision_set_user_role', { p_user_id: id, p_role: role, p_reason: 'fixture lokal' });
    expectOk(pr, `provision ${label}`, [200]);
  }
  // Login ulang agar sesi mencerminkan keadaan setelah provisioning (role aplikasi tetap dibaca dari profiles).
  const si = await auth.signIn(email, PASSWORD);
  expectOk(si, `login ${label}`, [200]);
  return { label, id, email, password: PASSWORD, token: si.body.access_token, refresh: si.body.refresh_token };
}

// Koordinat/tarif SINTETIS untuk DB lokal saja; bukan keputusan bisnis wilayah/ongkir.
export const FIX = { lat: -6.2, lon: 106.8, fee: 8000, radius: 5, nearLat: -6.21, nearLon: 106.81, farLat: -6.5, farLon: 107.2 };

export async function makeStore(seller, admin, name, { configure = true, activate = true } = {}) {
  const ins = await rest('POST', '/stores', {
    token: seller.token,
    headers: { Prefer: 'return=representation' },
    body: { owner_id: seller.id, name, address: `Alamat ${name}`, latitude: FIX.lat, longitude: FIX.lon },
  });
  expectOk(ins, `seller insert store ${name}`, [201]);
  const store = ins.body[0];
  if (configure) {
    expectOk(await rpc('admin_set_store_delivery_config', {
      p_store_id: store.id, p_delivery_fee: FIX.fee, p_service_radius_km: FIX.radius,
    }, admin.token), 'admin delivery config', [200, 204]);
  }
  if (activate) expectOk(await rpc('admin_set_store_active', { p_store_id: store.id, p_active: true }, admin.token), 'activate', [200]);
  return store;
}

export async function makeProduct(seller, storeId, name, price, extra = {}) {
  const res = await rest('POST', '/products', {
    token: seller.token,
    headers: { Prefer: 'return=representation' },
    body: { store_id: storeId, name, price, ...extra },
  });
  expectOk(res, `seller insert product ${name}`, [201]);
  return res.body[0];
}

export async function world() {
  const [admin, customerA, customerB, sellerA, sellerB, driverA, driverB] = await Promise.all([
    makeUser('admin', 'admin'), makeUser('custa'), makeUser('custb'),
    makeUser('sellera', 'seller'), makeUser('sellerb', 'seller'),
    makeUser('drivera', 'driver'), makeUser('driverb', 'driver'),
  ]);
  const storeA = await makeStore(sellerA, admin, `Toko A ${run}`);
  const storeB = await makeStore(sellerB, admin, `Toko B ${run}`);
  const pA1 = await makeProduct(sellerA, storeA.id, `Nasi ${run}`, 10000);
  const pA2 = await makeProduct(sellerA, storeA.id, `Teh ${run}`, 5000);
  const pAoff = await makeProduct(sellerA, storeA.id, `Habis ${run}`, 7000, { is_available: false });
  const pB1 = await makeProduct(sellerB, storeB.id, `Mie ${run}`, 12000);
  return { admin, customerA, customerB, sellerA, sellerB, driverA, driverB, storeA, storeB, pA1, pA2, pAoff, pB1 };
}

export const key = (p = 'k') => `${p}-${randomUUID()}`;
export const orderArgs = (store, items, extra = {}) => ({
  p_store_id: store.id,
  p_items: items,
  p_delivery_address: 'Jl. Uji Lokal 1',
  p_delivery_latitude: FIX.nearLat,
  p_delivery_longitude: FIX.nearLon,
  p_delivery_note: null,
  p_payment_method: 'cod',
  p_idempotency_key: key('ord'),
  ...extra,
});
