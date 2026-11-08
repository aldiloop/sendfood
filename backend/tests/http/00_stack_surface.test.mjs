// Permukaan API nyata: layanan hidup, dan fungsi/tabel yang terekspos ke anon/authenticated sesuai kontrak.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cfg, rest, sql, auth } from './lib/client.mjs';

test('GoTrue /health dan PostgREST root merespons (layanan asli, localhost)', async () => {
  const h = await fetch(`${cfg.auth}/health`);
  assert.equal(h.status, 200);
  const body = await h.json();
  assert.ok(body.version || body.name, 'GoTrue health tanpa versi');
  const r = await rest('GET', '/');
  assert.equal(r.status, 200, `PostgREST root ${r.status}`);
  assert.ok(r.body?.paths, 'OpenAPI PostgREST tidak ada');
});

test('signup tanpa email/password ditolak GoTrue (422/400)', async () => {
  const r = await auth.signUp('', '', {});
  assert.ok([400, 422].includes(r.status), `status ${r.status}`);
});

// Fungsi public yang bisa di-EXECUTE peran klien. Daftar ini adalah permukaan /rest/v1/rpc yang sah.
const EXPECTED_ANON = ['haversine_km', 'list_stores', 'search_products', 'validate_catalog_params'];
const EXPECTED_AUTH = [
  'admin_get_policies', 'admin_set_product_available', 'admin_set_store_active', 'admin_set_store_delivery_config',
  'assign_order_driver', 'change_order_status', 'create_order', 'current_app_role', 'haversine_km',
  'list_my_orders', 'list_stores', 'record_cod_collection', 'search_products', 'validate_catalog_params',
];
const execList = (role) => sql(`select string_agg(distinct p.proname, ',' order by p.proname) from pg_proc p
  where p.pronamespace = 'public'::regnamespace and p.prorettype <> 'trigger'::regtype
    and has_function_privilege('${role}', p.oid, 'execute')`).split(',').filter(Boolean);

test('anon hanya dapat EXECUTE fungsi katalog publik', () => {
  assert.deepEqual(execList('anon'), EXPECTED_ANON);
});
test('authenticated dapat EXECUTE persis RPC kontrak (tanpa provision_*/ops_policy_value)', () => {
  assert.deepEqual(execList('authenticated'), EXPECTED_AUTH);
});
test('provision_* hanya untuk service_role', () => {
  const r = sql(`select string_agg(p.proname || ':' || has_function_privilege('service_role', p.oid, 'execute')::text, ',' order by p.proname)
    from pg_proc p where p.pronamespace='public'::regnamespace and p.proname like 'provision_%'`);
  assert.equal(r, 'provision_set_policy:true,provision_set_user_role:true');
});

test('RLS aktif di semua tabel public', () => {
  const off = sql(`select coalesce(string_agg(relname, ','), '') from pg_class
    where relnamespace='public'::regnamespace and relkind='r' and not relrowsecurity`);
  assert.equal(off, '');
});

test('fungsi trigger tidak bisa dipanggil lewat /rpc', async () => {
  for (const fn of ['handle_new_auth_user', 'block_client_direct_write', 'guard_profile_update', 'touch_updated_at']) {
    const r = await rest('POST', `/rpc/${fn}`, { body: {} });
    assert.ok([401, 403, 404].includes(r.status), `${fn} -> ${r.status}`);
  }
});
