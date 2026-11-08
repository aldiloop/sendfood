-- Bootstrap peran/schema ala Supabase untuk STACK LOKAL sekali pakai (GoTrue + PostgREST asli).
-- JANGAN dijalankan di proyek Supabase: di sana semua ini sudah disediakan platform.
-- Dipanggil oleh backend/tests/stack/run_stack.sh dengan variabel psql:
--   -v authenticator_pw=... -v auth_admin_pw=...   (password acak per run, tidak disimpan)
-- Mengacu pada init script supabase/postgres (roles, schema auth/extensions, default privileges).
\set ON_ERROR_STOP on

do $$
begin
  if current_database() !~ '^sendfood_stack_' then
    raise exception 'bootstrap_refused_database_name_must_start_with_sendfood_stack_';
  end if;
  if exists (select 1 from pg_catalog.pg_namespace where nspname = 'auth') then
    raise exception 'bootstrap_refused_auth_schema_exists';
  end if;
end
$$;

-- Peran API: tidak bisa login langsung; PostgREST berganti peran via JWT claim "role".
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    create role authenticator login noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then
    create role supabase_auth_admin login noinherit createrole;
  end if;
end
$$;

alter role authenticator with password :'authenticator_pw';
alter role supabase_auth_admin with password :'auth_admin_pw';
grant anon, authenticated, service_role to authenticator;

-- Schema auth dimiliki GoTrue (migrasi GoTrue membuat tabel dan fungsi auth.uid()/auth.jwt()).
create schema auth authorization supabase_auth_admin;
alter role supabase_auth_admin set search_path = auth;
grant usage on schema auth to anon, authenticated, service_role, postgres;

create schema if not exists extensions;
grant usage on schema extensions to anon, authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;

-- Default privilege Supabase untuk objek baru buatan postgres di schema public.
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;

-- Batas waktu wajar untuk peran API (meniru setelan Supabase).
alter role anon set statement_timeout = '3s';
alter role authenticated set statement_timeout = '8s';
