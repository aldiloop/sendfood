-- Fixture dan helper tes. HANYA untuk database sementara sendfood_test_* (tidak pernah di migrasi).
-- Helper memakai skema t: t.login meniru PostgREST (SET ROLE + request.jwt.claims).
\set ON_ERROR_STOP on
do $$
begin
  if current_database() !~ '^sendfood_test_' then
    raise exception 'fixtures_refused_not_a_test_database';
  end if;
end
$$;

create schema t;
grant usage on schema t to public;

create function t.login(p_uid uuid, p_role text default 'authenticated') returns void
language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claims',
    case when p_uid is null then '' else json_build_object('sub', p_uid, 'role', p_role)::text end, true);
  execute format('set local role %I', p_role);
end $$;

create function t.logout() returns void
language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claims', '', true);
end $$;

create function t.ok(p_name text, p_cond boolean) returns void
language plpgsql as $$
begin
  if p_cond is true then raise notice 'PASS: %', p_name;
  else raise notice 'FAIL: % (kondisi tidak terpenuhi)', p_name; end if;
end $$;

create function t.skip(p_name text, p_reason text) returns void
language plpgsql as $$
begin raise notice 'SKIP: % (%)', p_name, p_reason; end $$;

-- Menjalankan SQL dan mengharapkan error yang pesannya memuat p_expected.
create function t.expect_err(p_name text, p_sql text, p_expected text) returns void
language plpgsql as $$
declare v_msg text;
begin
  begin
    execute p_sql;
  exception when others then
    v_msg := sqlerrm;
    if position(p_expected in v_msg) > 0 then raise notice 'PASS: %', p_name;
    else raise notice 'FAIL: % (diharapkan "%", didapat "%")', p_name, p_expected, v_msg; end if;
    return;
  end;
  raise notice 'FAIL: % (tidak ada error, diharapkan "%")', p_name, p_expected;
end $$;

-- Pembungkus create_order dengan nilai default alamat/koordinat dalam radius toko A.
create function t.co_sql(p_store uuid, p_items jsonb, p_lat text default '-6.21', p_lon text default '106.81',
  p_pm text default 'cod', p_key text default null) returns text
language sql as $$
  select format('select * from public.create_order(%L::uuid, %L::jsonb, ''Jl. Tujuan 1'', %s::numeric, %s::numeric, null, %L::public.payment_method, %L)',
    p_store, p_items, p_lat, p_lon, p_pm, p_key)
$$;

create function t.try_order(p_name text, p_expected text, p_store uuid, p_items jsonb,
  p_lat text default '-6.21', p_lon text default '106.81', p_pm text default 'cod', p_key text default null) returns void
language plpgsql as $$
begin
  perform t.expect_err(p_name, t.co_sql(p_store, p_items, p_lat, p_lon, p_pm, p_key), p_expected);
end $$;

-- Membuat order sebagai customer lalu mengembalikan id (dipakai di dalam transaksi tes).
create function t.make_order(p_cust uuid, p_store uuid, p_items jsonb, p_key text default null) returns uuid
language plpgsql as $$
declare v_id uuid;
begin
  perform t.login(p_cust);
  select o.order_id into v_id from public.create_order(p_store, p_items, 'Jl. Tujuan 1', -6.21, 106.81, null, 'cod', p_key) o;
  perform t.logout();
  return v_id;
end $$;

create function t.status_as(p_uid uuid, p_order uuid, p_status text, p_note text default null) returns void
language plpgsql as $$
begin
  perform t.login(p_uid);
  perform public.change_order_status(p_order, p_status::public.order_status, p_note);
  perform t.logout();
end $$;

-- Akun terpisah per peran.
insert into auth.users (id, email) values
  ('10000000-0000-0000-0000-00000000000a', 'cust-a@example.test'),
  ('10000000-0000-0000-0000-00000000000b', 'cust-b@example.test'),
  ('20000000-0000-0000-0000-00000000000a', 'seller-a@example.test'),
  ('20000000-0000-0000-0000-00000000000b', 'seller-b@example.test'),
  ('30000000-0000-0000-0000-00000000000a', 'driver-a@example.test'),
  ('30000000-0000-0000-0000-00000000000b', 'driver-b@example.test'),
  ('40000000-0000-0000-0000-000000000001', 'admin@example.test');
select public.provision_set_user_role('20000000-0000-0000-0000-00000000000a', 'seller', 'fixture');
select public.provision_set_user_role('20000000-0000-0000-0000-00000000000b', 'seller', 'fixture');
select public.provision_set_user_role('30000000-0000-0000-0000-00000000000a', 'driver', 'fixture');
select public.provision_set_user_role('30000000-0000-0000-0000-00000000000b', 'driver', 'fixture');
select public.provision_set_user_role('40000000-0000-0000-0000-000000000001', 'admin', 'fixture');
-- FIXTURE SINTETIS (DB sekali pakai), BUKAN keputusan bisnis: migrasi tidak menyetel aktor completion,
-- jadi tes alur yang sampai `completed` menyetelnya eksplisit lewat provisioning tepercaya.
-- Regresi tanpa kebijakan ada di 80_completion_policy.sql.
select public.provision_set_policy('completion_actor', 'customer');

-- Toko A (seller A): aktif, terkonfigurasi. Toko B (seller B): aktif, terkonfigurasi.
-- Toko Nonaktif (seller A). Toko Belum Setting (seller B): aktif tanpa fee/radius.
insert into public.stores (id, owner_id, name, description, address, latitude, longitude, is_active, delivery_fee, service_radius_km) values
  ('50000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-00000000000a', 'Warung A', 'Makanan rumahan', 'Jl. A 1', -6.200000, 106.800000, true, 5000, 5),
  ('50000000-0000-0000-0000-00000000000b', '20000000-0000-0000-0000-00000000000b', 'Toko B', 'Aneka nasi', 'Jl. B 2', -6.220000, 106.820000, true, 7000, 3),
  ('50000000-0000-0000-0000-00000000000c', '20000000-0000-0000-0000-00000000000a', 'Toko Nonaktif', null, 'Jl. C 3', -6.200000, 106.800000, false, 5000, 5),
  ('50000000-0000-0000-0000-00000000000d', '20000000-0000-0000-0000-00000000000b', 'Kedai Belum Setting', null, 'Jl. D 4', -6.250000, 106.850000, true, null, null);

insert into public.products (id, store_id, name, price, is_available) values
  ('60000000-0000-0000-0000-0000000000a1', '50000000-0000-0000-0000-00000000000a', 'Nasi Goreng A', 10000, true),
  ('60000000-0000-0000-0000-0000000000a2', '50000000-0000-0000-0000-00000000000a', 'Teh Manis A', 4000, true),
  ('60000000-0000-0000-0000-0000000000a3', '50000000-0000-0000-0000-00000000000a', 'Sate Habis', 3000, false),
  ('60000000-0000-0000-0000-0000000000b1', '50000000-0000-0000-0000-00000000000b', 'Nasi Uduk B', 12000, true),
  ('60000000-0000-0000-0000-0000000000c1', '50000000-0000-0000-0000-00000000000c', 'Mie Toko Nonaktif', 8000, true),
  ('60000000-0000-0000-0000-0000000000d1', '50000000-0000-0000-0000-00000000000d', 'Bakso Belum Setting', 9000, true);

select 'fixtures: 7 akun, 4 toko, 6 produk' as info;
