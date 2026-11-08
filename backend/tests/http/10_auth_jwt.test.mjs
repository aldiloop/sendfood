// Supabase Auth (GoTrue) asli + verifikasi JWT oleh PostgREST asli.
import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { cfg, auth, rest, rpc, service, sql, makeUser, run, expectError, expectOk } from './lib/client.mjs';
import { signHS256, decodePayload, unsignedToken, tamperPayload } from './lib/jwt.mjs';

let cust, other;
before(async () => {
  cust = await makeUser('authcust', 'customer', { role: 'admin', app_role: 'admin' });
  other = await makeUser('authother');
});

test('registrasi: profil dibuat trigger dengan role customer walau metadata signup meminta admin', async () => {
  assert.equal(sql(`select role from public.profiles where id='${cust.id}'`), 'customer');
  assert.equal(sql(`select full_name from public.profiles where id='${cust.id}'`), 'Uji authcust');
  const me = await rest('GET', `/profiles?id=eq.${cust.id}&select=id,role`, { token: cust.token });
  expectOk(me, 'baca profil sendiri');
  assert.deepEqual(me.body, [{ id: cust.id, role: 'customer' }]);
  const cr = await rpc('current_app_role', {}, cust.token);
  assert.equal(cr.body, 'customer');
});

test('JWT GoTrue: HS256, role=authenticated, aud=authenticated, sub=user id, exp ~1 jam', () => {
  const p = decodePayload(cust.token);
  assert.equal(p.role, 'authenticated');
  assert.equal(p.aud, 'authenticated');
  assert.equal(p.sub, cust.id);
  assert.ok(p.exp - p.iat <= 3600 && p.exp - p.iat > 3000, `exp-iat=${p.exp - p.iat}`);
  assert.equal(p.user_metadata?.role, 'admin', 'metadata tetap tersimpan, tetapi diabaikan aplikasi');
});

test('login: password salah ditolak; email tidak terdaftar ditolak', async () => {
  expectError(await auth.signIn(cust.email, 'salah-sekali-123'), { status: 400 }, 'password salah');
  expectError(await auth.signIn(`tidakada.${run}@sendfood.test`, 'Whatever-123'), { status: 400 }, 'email tidak ada');
});

test('signup: password terlalu pendek ditolak (422)', async () => {
  expectError(await auth.signUp(`pendek.${run}@sendfood.test`, 'abc', {}), { status: 422 }, 'password pendek');
});

test('signup duplikat tidak membuat profil kedua', async () => {
  const before = Number(sql(`select count(*) from public.profiles`));
  await auth.signUp(cust.email, 'Another-Pw-12345', {});
  assert.equal(Number(sql(`select count(*) from public.profiles`)), before);
});

test('PostgREST menolak token palsu: secret salah, alg none, payload diubah, kedaluwarsa, sampah', async () => {
  const now = Math.floor(Date.now() / 1000);
  const claims = { sub: cust.id, role: 'authenticated', aud: 'authenticated', iat: now, exp: now + 600 };
  const cases = {
    'secret salah': signHS256(claims, 'bukan-secret-yang-benar-0123456789abcdef'),
    'alg none': unsignedToken(claims),
    'payload diubah (sub orang lain)': tamperPayload(cust.token, { sub: other.id }),
    'payload diubah (role service_role)': tamperPayload(cust.token, { role: 'service_role' }),
    'kedaluwarsa (secret benar)': signHS256({ ...claims, iat: now - 7200, exp: now - 3600 }, cfg.jwtSecret),
    'bukan JWT': 'abc.def.ghi',
  };
  for (const [label, tok] of Object.entries(cases)) {
    const r = await rest('GET', '/profiles?select=id', { token: tok });
    assert.equal(r.status, 401, `${label}: PostgREST ${r.status} ${r.body?.code}`);
    assert.match(String(r.body?.code), /^PGRST30[0-3]$/, `${label}: kode ${r.body?.code}`);
  }
});

test('GoTrue /user menolak token palsu dan kedaluwarsa', async () => {
  const now = Math.floor(Date.now() / 1000);
  const expired = signHS256({ sub: cust.id, role: 'authenticated', aud: 'authenticated', iat: now - 7200, exp: now - 3600 }, cfg.jwtSecret);
  expectError(await auth.user(expired), { status: [401, 403] }, '/user expired');
  expectError(await auth.user(tamperPayload(cust.token, { sub: other.id })), { status: [401, 403] }, '/user tampered');
  const ok = await auth.user(cust.token);
  expectOk(ok, '/user valid');
  assert.equal(ok.body.id, cust.id);
});

test('JWT valid ditandatangani secret benar tetapi role=service_role: hanya mungkin dengan secret server', async () => {
  // Bukti bahwa service_role melewati RLS -> secret JWT wajib tetap di server (tidak pernah di frontend).
  const r = await service.rpc('admin_get_policies', {});
  // service_role bukan admin aplikasi: auth.uid() null -> admin_role_required.
  expectError(r, { status: 400, message: 'admin_role_required' }, 'service tanpa sub');
});

test('metadata pengguna tidak dapat menaikkan role (PUT /user data.role=admin)', async () => {
  const up = await auth.update(cust.token, { data: { role: 'admin', app_role: 'admin' } });
  expectOk(up, 'update metadata');
  const si = await auth.signIn(cust.email, cust.password);
  const tok = si.body.access_token;
  assert.equal(decodePayload(tok).role, 'authenticated');
  assert.equal(sql(`select role from public.profiles where id='${cust.id}'`), 'customer');
  expectError(await rpc('admin_get_policies', {}, tok), { status: 400, message: 'admin_role_required' }, 'admin rpc');
});

test('app_metadata tidak bisa diubah pengguna lewat /user', async () => {
  await auth.update(cust.token, { app_metadata: { role: 'admin' } });
  const raw = sql(`select coalesce(raw_app_meta_data->>'role','') from auth.users where id='${cust.id}'`);
  assert.equal(raw, '');
});

test('role tidak bisa dinaikkan lewat PostgREST (PATCH profiles.role / provision_*)', async () => {
  const p = await rest('PATCH', `/profiles?id=eq.${cust.id}`, { token: cust.token, body: { role: 'admin' } });
  expectError(p, { status: [401, 403] }, 'patch role');
  assert.equal(p.body?.code, '42501');
  const pr = await rpc('provision_set_user_role', { p_user_id: cust.id, p_role: 'admin' }, cust.token);
  expectError(pr, { status: [401, 403, 404] }, 'provision by user');
  const pa = await rpc('provision_set_user_role', { p_user_id: cust.id, p_role: 'admin' });
  expectError(pa, { status: [401, 403, 404] }, 'provision by anon');
  const pol = await rpc('provision_set_policy', { p_key: 'cancellation_enabled', p_value: 'true' }, cust.token);
  expectError(pol, { status: [401, 403, 404] }, 'policy by user');
  assert.equal(sql(`select role from public.profiles where id='${cust.id}'`), 'customer');
  assert.equal(sql(`select value from public.ops_policy where key='cancellation_enabled'`), 'false');
});

test('profil: pengguna boleh ubah full_name sendiri, tidak boleh profil orang lain', async () => {
  const own = await rest('PATCH', `/profiles?id=eq.${cust.id}`, {
    token: cust.token, headers: { Prefer: 'return=representation' }, body: { full_name: 'Nama Baru' } });
  expectOk(own, 'patch nama sendiri');
  assert.equal(own.body[0].full_name, 'Nama Baru');
  const foreign = await rest('PATCH', `/profiles?id=eq.${other.id}`, {
    token: cust.token, headers: { Prefer: 'return=representation' }, body: { full_name: 'Dibajak' } });
  // RLS menyaring baris: 0 baris terubah.
  assert.equal(foreign.status, 200);
  assert.deepEqual(foreign.body, []);
  assert.equal(sql(`select full_name from public.profiles where id='${other.id}'`), 'Uji authother');
});

test('refresh token: rotasi bekerja; pemakaian ulang token lama ditolak dan mencabut seluruh keluarga sesi', async () => {
  const s = await auth.signIn(other.email, other.password);
  const t1 = await auth.refresh(s.body.refresh_token);
  expectOk(t1, 'refresh 1');
  assert.ok(t1.body.access_token && t1.body.refresh_token !== s.body.refresh_token, 'token dirotasi');
  // Perilaku GoTrue v2.197: memakai ulang parent LANGSUNG dari token aktif mengembalikan sesi aktif yang sama
  // (toleransi refresh bersamaan), bukan token baru.
  const parentReuse = await auth.refresh(s.body.refresh_token);
  expectOk(parentReuse, 'reuse parent langsung');
  assert.equal(parentReuse.body.refresh_token, t1.body.refresh_token, 'harus token aktif yang sama');
  const t2 = await auth.refresh(t1.body.refresh_token);
  const t3 = await auth.refresh(t2.body.refresh_token);
  expectOk(t3, 'refresh 3');
  const stale = await auth.refresh(s.body.refresh_token);
  expectError(stale, { status: 400 }, 'reuse token lama');
  assert.equal(stale.body?.error_code, 'refresh_token_already_used');
  const current = await auth.refresh(t3.body.refresh_token);
  expectError(current, { status: 400 }, 'token aktif setelah reuse terdeteksi');
  assert.equal(current.body?.error_code, 'refresh_token_already_used');
});

test('logout: refresh token dicabut; GoTrue /user menolak sesi; access token stateless tetap diterima PostgREST sampai exp', async () => {
  const s = await auth.signIn(other.email, other.password);
  expectOk(await auth.logout(s.body.access_token), 'logout', [204]);
  expectError(await auth.refresh(s.body.refresh_token), { status: [400, 401] }, 'refresh setelah logout');
  const u = await auth.user(s.body.access_token);
  assert.ok([401, 403].includes(u.status), `/user setelah logout ${u.status}`);
  // Perilaku bawaan Supabase: PostgREST hanya memverifikasi tanda tangan+exp, tidak status sesi.
  const r = await rest('GET', `/profiles?id=eq.${other.id}&select=id`, { token: s.body.access_token });
  assert.equal(r.status, 200, 'dokumentasikan: access token berlaku sampai exp');
});

test('anon key tanpa sesi tidak dapat membaca profil', async () => {
  const r = await rest('GET', '/profiles?select=id');
  expectError(r, { status: 401, code: '42501' }, 'anon profiles');
});
