-- SendFood backend MVP hardening (forward migration, v2)
-- Applies on top of 20261107000000_sendfood_backend_foundation.sql (do not edit that file).
--
-- Principles:
-- * Operational decisions that are NOT approved yet stay fail-closed
--   (manual transfer, cancellation, COD collection recording). They are gated by
--   public.ops_policy rows that only trusted operators can write.
-- * delivered/completed NEVER marks payment as paid.
-- * No rating tables or fields (rating is P2 and deferred).
-- * Supabase default privileges grant execute/table access to anon/authenticated/
--   service_role, so every new object below revokes explicitly and re-grants minimally.
-- * Atomic and fail-fast on every apply path: the whole file is one explicit transaction
--   (BEGIN ... COMMIT), so a failure anywhere rolls back schema, catalog and data even when run
--   with plain `psql -f` or pasted into an SQL editor. Always use ON_ERROR_STOP with psql.
--   lock_timeout makes it fail instead of queueing behind long-held locks on a live database.

begin;
set local lock_timeout = '5s';
set local statement_timeout = '120s';

do $$
begin
  if to_regclass('auth.users') is null then
    raise exception using errcode = 'P0001', message = 'hardening_requires_supabase_auth_schema';
  end if;
  if to_regclass('public.profiles') is null or to_regclass('public.orders') is null
     or to_regclass('public.products') is null then
    raise exception using errcode = 'P0001', message = 'hardening_requires_foundation_migration';
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- 1. Operational policy table (trusted write only) and audit log
-- ---------------------------------------------------------------------------

create table if not exists public.ops_policy (
  key text primary key,
  value text not null,
  updated_at timestamptz not null default now()
);
alter table public.ops_policy enable row level security;
revoke all on table public.ops_policy from public, anon, authenticated;

-- Defaults are fail-closed except completion_actor, which keeps the existing
-- provisional convention (customer confirms receipt).
insert into public.ops_policy (key, value) values
  ('completion_actor', 'customer'),
  ('cancellation_enabled', 'false'),
  ('manual_transfer_enabled', 'false'),
  ('cod_collection_recording_enabled', 'false')
on conflict (key) do nothing;

create table if not exists public.admin_audit_log (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references public.profiles(id) on delete set null,
  action text not null,
  target_type text not null,
  target_id text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists admin_audit_log_created_idx on public.admin_audit_log(created_at desc);
alter table public.admin_audit_log enable row level security;
revoke all on table public.admin_audit_log from public, anon, authenticated;
grant select on public.admin_audit_log to authenticated;
drop policy if exists admin_audit_log_admin_read on public.admin_audit_log;
create policy admin_audit_log_admin_read on public.admin_audit_log
  for select to authenticated
  using (public.current_app_role() = 'admin');

create or replace function public.ops_policy_value(p_key text)
returns text
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select p.value from public.ops_policy p where p.key = p_key
$$;
revoke all on function public.ops_policy_value(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Direct-write protection and role escalation guards
-- ---------------------------------------------------------------------------

-- Client roles (anon/authenticated) must never write operational tables directly.
-- SECURITY DEFINER RPCs run as the function owner, so they are not affected.
create or replace function public.block_client_direct_write()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if current_user in ('anon', 'authenticated') then
    raise exception using errcode = 'P0001', message = 'direct_write_forbidden';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;
revoke all on function public.block_client_direct_write() from public, anon, authenticated;

drop trigger if exists orders_block_client_write on public.orders;
create trigger orders_block_client_write
  before insert or update or delete on public.orders
  for each row execute function public.block_client_direct_write();
drop trigger if exists order_items_block_client_write on public.order_items;
create trigger order_items_block_client_write
  before insert or update or delete on public.order_items
  for each row execute function public.block_client_direct_write();
drop trigger if exists order_status_history_block_client_write on public.order_status_history;
create trigger order_status_history_block_client_write
  before insert or update or delete on public.order_status_history
  for each row execute function public.block_client_direct_write();

create or replace function public.guard_profile_update()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if current_user in ('anon', 'authenticated')
     and (new.role is distinct from old.role
          or new.id is distinct from old.id
          or new.created_at is distinct from old.created_at) then
    raise exception using errcode = 'P0001', message = 'profile_role_change_forbidden';
  end if;
  return new;
end;
$$;
revoke all on function public.guard_profile_update() from public, anon, authenticated;
drop trigger if exists profiles_guard_update on public.profiles;
create trigger profiles_guard_update
  before update on public.profiles
  for each row execute function public.guard_profile_update();

-- Sellers may not move an active store: the service radius check depends on it.
create or replace function public.guard_store_update()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if current_user in ('anon', 'authenticated') then
    if new.owner_id is distinct from old.owner_id
       or new.is_active is distinct from old.is_active
       or new.delivery_fee is distinct from old.delivery_fee
       or new.service_radius_km is distinct from old.service_radius_km then
      raise exception using errcode = 'P0001', message = 'store_operational_field_forbidden';
    end if;
    if old.is_active
       and (new.latitude is distinct from old.latitude or new.longitude is distinct from old.longitude) then
      raise exception using errcode = 'P0001', message = 'store_location_locked';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.guard_store_update() from public, anon, authenticated;
drop trigger if exists stores_guard_update on public.stores;
create trigger stores_guard_update
  before update on public.stores
  for each row execute function public.guard_store_update();

-- Products: store_id and timestamps cannot be changed/forged by the client.
-- PostgreSQL numeric NaN compares >= 0; exclude it explicitly from prices.
alter table public.products drop constraint if exists products_price_not_nan;
alter table public.products add constraint products_price_not_nan
  check (price <> 'NaN'::numeric);
-- Same for every other money/radius column (foundation only checks >= 0, which NaN passes; NaN = NaN is
-- also true, so total = subtotal + delivery_fee does not catch it). Infinity cannot be stored in these
-- typmod-constrained numeric columns, so NaN is the only non-finite value to exclude. Coordinates are
-- already safe: their foundation range checks (between -90 and 90 etc.) are false for NaN.
-- Legacy NaN rows make these ADD CONSTRAINTs fail (SQLSTATE 23514) and the whole migration roll back;
-- they are never rewritten automatically (see backend/README.md preflight).
alter table public.stores drop constraint if exists stores_delivery_fee_not_nan;
alter table public.stores add constraint stores_delivery_fee_not_nan
  check (delivery_fee is null or delivery_fee <> 'NaN'::numeric);
alter table public.stores drop constraint if exists stores_service_radius_not_nan;
alter table public.stores add constraint stores_service_radius_not_nan
  check (service_radius_km is null or service_radius_km <> 'NaN'::numeric);
alter table public.orders drop constraint if exists orders_amounts_not_nan;
alter table public.orders add constraint orders_amounts_not_nan
  check (subtotal <> 'NaN'::numeric and delivery_fee <> 'NaN'::numeric and total <> 'NaN'::numeric);
alter table public.order_items drop constraint if exists order_items_amounts_not_nan;
alter table public.order_items add constraint order_items_amounts_not_nan
  check (unit_price_snapshot <> 'NaN'::numeric and line_total <> 'NaN'::numeric);
revoke insert, update on public.products from authenticated;
grant insert (store_id, name, description, price, image_url, is_available) on public.products to authenticated;
grant update (name, description, price, image_url, is_available) on public.products to authenticated;

-- order_items / history are scoped by orders RLS (the subquery runs under the caller's RLS).
-- Re-declared explicitly so the intent is visible and the policies do not depend on that subtlety.
drop policy if exists order_items_participant_read on public.order_items;
create policy order_items_participant_read on public.order_items
  for select to authenticated
  using (exists (
    select 1 from public.orders o
    where o.id = order_items.order_id
      and (o.customer_id = auth.uid()
           or o.driver_id = auth.uid()
           or public.current_app_role() = 'admin'
           or exists (select 1 from public.stores s where s.id = o.store_id and s.owner_id = auth.uid()))
  ));
drop policy if exists order_status_history_participant_read on public.order_status_history;
create policy order_status_history_participant_read on public.order_status_history
  for select to authenticated
  using (exists (
    select 1 from public.orders o
    where o.id = order_status_history.order_id
      and (o.customer_id = auth.uid()
           or o.driver_id = auth.uid()
           or public.current_app_role() = 'admin'
           or exists (select 1 from public.stores s where s.id = o.store_id and s.owner_id = auth.uid()))
  ));

-- ---------------------------------------------------------------------------
-- 3. Saved customer addresses (minimal)
-- ---------------------------------------------------------------------------

create table if not exists public.customer_addresses (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  label text not null check (char_length(btrim(label)) between 1 and 60),
  address text not null check (char_length(btrim(address)) between 1 and 1500),
  latitude numeric(9,6),
  longitude numeric(9,6),
  note text check (note is null or char_length(note) <= 1000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint customer_addresses_coordinate_pair check ((latitude is null) = (longitude is null)),
  constraint customer_addresses_latitude_range check (latitude is null or latitude between -90 and 90),
  constraint customer_addresses_longitude_range check (longitude is null or longitude between -180 and 180)
);
create index if not exists customer_addresses_customer_idx on public.customer_addresses(customer_id);

drop trigger if exists customer_addresses_touch_updated_at on public.customer_addresses;
create trigger customer_addresses_touch_updated_at before update on public.customer_addresses
  for each row execute function public.touch_updated_at();

create or replace function public.limit_customer_addresses()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  -- Serialkan cek+insert per customer (bukan lock global): tanpa ini dua INSERT
  -- bersamaan pada 9 alamat sama-sama melihat count=9 dan lolos ke 11.
  -- Lock transaksi dilepas otomatis saat commit/rollback.
  perform pg_advisory_xact_lock(hashtextextended('customer_addresses:' || new.customer_id::text, 0));
  if (select count(*) from public.customer_addresses a where a.customer_id = new.customer_id) >= 10 then
    raise exception using errcode = 'P0001', message = 'address_limit_reached';
  end if;
  return new;
end;
$$;
revoke all on function public.limit_customer_addresses() from public, anon, authenticated;
drop trigger if exists customer_addresses_limit on public.customer_addresses;
create trigger customer_addresses_limit before insert on public.customer_addresses
  for each row execute function public.limit_customer_addresses();

alter table public.customer_addresses enable row level security;
revoke all on table public.customer_addresses from public, anon, authenticated;
grant select, delete on public.customer_addresses to authenticated;
grant insert (label, address, latitude, longitude, note) on public.customer_addresses to authenticated;
grant update (label, address, latitude, longitude, note) on public.customer_addresses to authenticated;

drop policy if exists customer_addresses_select_own on public.customer_addresses;
create policy customer_addresses_select_own on public.customer_addresses
  for select to authenticated using (customer_id = auth.uid());
drop policy if exists customer_addresses_insert_own on public.customer_addresses;
create policy customer_addresses_insert_own on public.customer_addresses
  for insert to authenticated
  with check (customer_id = auth.uid() and public.current_app_role() = 'customer');
drop policy if exists customer_addresses_update_own on public.customer_addresses;
create policy customer_addresses_update_own on public.customer_addresses
  for update to authenticated
  using (customer_id = auth.uid())
  with check (customer_id = auth.uid() and public.current_app_role() = 'customer');
drop policy if exists customer_addresses_delete_own on public.customer_addresses;
create policy customer_addresses_delete_own on public.customer_addresses
  for delete to authenticated using (customer_id = auth.uid());

-- ---------------------------------------------------------------------------
-- 4. Catalog: distance helper, list_stores, search_products (real data, no rating)
-- ---------------------------------------------------------------------------

create or replace function public.haversine_km(lat1 numeric, lon1 numeric, lat2 numeric, lon2 numeric)
returns double precision
language sql
immutable
set search_path = pg_catalog, public
as $$
  select case when lat1 is null or lon1 is null or lat2 is null or lon2 is null then null
  else 2 * 6371.0088 * asin(sqrt(least(1.0, greatest(0.0,
    power(sin(radians((lat2 - lat1)::double precision) / 2), 2)
    + cos(radians(lat1::double precision)) * cos(radians(lat2::double precision))
      * power(sin(radians((lon2 - lon1)::double precision) / 2), 2)))))
  end
$$;
revoke all on function public.haversine_km(numeric, numeric, numeric, numeric) from public;
grant execute on function public.haversine_km(numeric, numeric, numeric, numeric) to anon, authenticated;

-- Shared validation for catalog parameters.
create or replace function public.validate_catalog_params(
  p_query text, p_latitude numeric, p_longitude numeric, p_sort text,
  p_allowed_sorts text[], p_limit integer, p_offset integer
)
returns text
language plpgsql
immutable
set search_path = pg_catalog, public
as $$
begin
  if p_query is not null and char_length(p_query) > 100 then
    raise exception using errcode = 'P0001', message = 'search_query_too_long';
  end if;
  if p_limit is null or p_limit not between 1 and 100 or p_offset is null or p_offset < 0 then
    raise exception using errcode = 'P0001', message = 'invalid_pagination';
  end if;
  if p_sort is null or not (p_sort = any (p_allowed_sorts)) then
    raise exception using errcode = 'P0001', message = 'invalid_sort';
  end if;
  if (p_latitude is null) <> (p_longitude is null) then
    raise exception using errcode = 'P0001', message = 'valid_coordinates_required';
  end if;
  if p_latitude is not null and (p_latitude not between -90 and 90 or p_longitude not between -180 and 180) then
    raise exception using errcode = 'P0001', message = 'valid_coordinates_required';
  end if;
  if p_sort in ('nearest', 'farthest') and p_latitude is null then
    raise exception using errcode = 'P0001', message = 'location_required_for_sort';
  end if;
  -- Escaped ILIKE pattern ('' when no query).
  if p_query is null or btrim(p_query) = '' then
    return '';
  end if;
  return '%' || replace(replace(replace(btrim(p_query), '\', '\\'), '%', '\%'), '_', '\_') || '%';
end;
$$;
revoke all on function public.validate_catalog_params(text, numeric, numeric, text, text[], integer, integer) from public;
grant execute on function public.validate_catalog_params(text, numeric, numeric, text, text[], integer, integer) to anon, authenticated;

-- SECURITY INVOKER: RLS decides what the caller can see; we additionally require active stores.
create or replace function public.list_stores(
  p_query text default null,
  p_latitude numeric default null,
  p_longitude numeric default null,
  p_sort text default 'name',
  p_limit integer default 20,
  p_offset integer default 0
)
returns table (
  id uuid, name text, description text, address text,
  latitude numeric, longitude numeric, phone text, image_url text, opening_hours jsonb,
  delivery_fee numeric, service_radius_km numeric,
  distance_km double precision, within_service_radius boolean
)
language plpgsql
stable
security invoker
set search_path = pg_catalog, public
as $$
declare
  v_pattern text;
begin
  v_pattern := public.validate_catalog_params(
    p_query, p_latitude, p_longitude, p_sort,
    array['name', 'nearest', 'farthest', 'delivery_fee'], p_limit, p_offset);

  return query
  select q.id, q.name, q.description, q.address, q.latitude, q.longitude, q.phone, q.image_url,
         q.opening_hours, q.delivery_fee, q.service_radius_km, q.dist,
         case when q.dist is null or q.service_radius_km is null then null
              when q.dist = 'NaN'::double precision or q.service_radius_km = 'NaN'::numeric then null
              else q.dist <= q.service_radius_km::double precision end
  from (
    select s.id, s.name, s.description, s.address, s.latitude, s.longitude, s.phone, s.image_url,
           s.opening_hours, s.delivery_fee, s.service_radius_km,
           public.haversine_km(p_latitude, p_longitude, s.latitude, s.longitude) as dist
    from public.stores s
    where s.is_active = true
      and (v_pattern = '' or s.name ilike v_pattern or s.description ilike v_pattern)
  ) q
  order by
    case when p_sort = 'nearest' then q.dist end asc nulls last,
    case when p_sort = 'farthest' then q.dist end desc nulls last,
    case when p_sort = 'delivery_fee' then q.delivery_fee end asc nulls last,
    q.name asc, q.id asc
  limit p_limit offset p_offset;
end;
$$;

create or replace function public.search_products(
  p_query text default null,
  p_store_id uuid default null,
  p_min_price numeric default null,
  p_max_price numeric default null,
  p_latitude numeric default null,
  p_longitude numeric default null,
  p_sort text default 'name',
  p_limit integer default 20,
  p_offset integer default 0
)
returns table (
  id uuid, store_id uuid, store_name text, name text, description text,
  price numeric, image_url text, delivery_fee numeric, service_radius_km numeric,
  distance_km double precision, within_service_radius boolean
)
language plpgsql
stable
security invoker
set search_path = pg_catalog, public
as $$
declare
  v_pattern text;
begin
  v_pattern := public.validate_catalog_params(
    p_query, p_latitude, p_longitude, p_sort,
    array['name', 'nearest', 'farthest', 'cheapest', 'priciest', 'delivery_fee'], p_limit, p_offset);
  if (p_min_price is not null and p_min_price < 0) or (p_max_price is not null and p_max_price < 0)
     or (p_min_price is not null and p_max_price is not null and p_min_price > p_max_price) then
    raise exception using errcode = 'P0001', message = 'invalid_price_range';
  end if;

  return query
  select q.id, q.store_id, q.store_name, q.name, q.description, q.price, q.image_url,
         q.delivery_fee, q.service_radius_km, q.dist,
         case when q.dist is null or q.service_radius_km is null then null
              when q.dist = 'NaN'::double precision or q.service_radius_km = 'NaN'::numeric then null
              else q.dist <= q.service_radius_km::double precision end
  from (
    select p.id, p.store_id, s.name as store_name, p.name, p.description, p.price, p.image_url,
           s.delivery_fee, s.service_radius_km,
           public.haversine_km(p_latitude, p_longitude, s.latitude, s.longitude) as dist
    from public.products p
    join public.stores s on s.id = p.store_id
    where s.is_active = true and p.is_available = true
      and (p_store_id is null or p.store_id = p_store_id)
      and (p_min_price is null or p.price >= p_min_price)
      and (p_max_price is null or p.price <= p_max_price)
      and (v_pattern = '' or p.name ilike v_pattern or p.description ilike v_pattern or s.name ilike v_pattern)
  ) q
  order by
    case when p_sort = 'nearest' then q.dist end asc nulls last,
    case when p_sort = 'farthest' then q.dist end desc nulls last,
    case when p_sort = 'cheapest' then q.price end asc nulls last,
    case when p_sort = 'priciest' then q.price end desc nulls last,
    case when p_sort = 'delivery_fee' then q.delivery_fee end asc nulls last,
    q.name asc, q.id asc
  limit p_limit offset p_offset;
end;
$$;

revoke all on function public.list_stores(text, numeric, numeric, text, integer, integer) from public;
grant execute on function public.list_stores(text, numeric, numeric, text, integer, integer) to anon, authenticated;
revoke all on function public.search_products(text, uuid, numeric, numeric, numeric, numeric, text, integer, integer) from public;
grant execute on function public.search_products(text, uuid, numeric, numeric, numeric, numeric, text, integer, integer) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Order history / driver tasks (role scoped, SECURITY INVOKER + RLS)
-- ---------------------------------------------------------------------------

create or replace function public.list_my_orders(
  p_status public.order_status default null,
  p_limit integer default 20,
  p_offset integer default 0
)
returns table (
  order_id uuid, order_code text, store_id uuid, store_name text, customer_id uuid, driver_id uuid,
  delivery_address text, delivery_latitude numeric, delivery_longitude numeric, delivery_note text,
  subtotal numeric, delivery_fee numeric, total numeric,
  payment_method public.payment_method, payment_status public.payment_status,
  order_status public.order_status, created_at timestamptz, items jsonb
)
language plpgsql
stable
security invoker
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := auth.uid();
  v_role public.app_role;
begin
  if v_uid is null then
    raise exception using errcode = 'P0001', message = 'authentication_required';
  end if;
  if p_limit is null or p_limit not between 1 and 100 or p_offset is null or p_offset < 0 then
    raise exception using errcode = 'P0001', message = 'invalid_pagination';
  end if;
  v_role := public.current_app_role();

  return query
  select o.id, o.order_code, o.store_id, s.name, o.customer_id, o.driver_id,
         o.delivery_address, o.delivery_latitude, o.delivery_longitude, o.delivery_note,
         o.subtotal, o.delivery_fee, o.total, o.payment_method, o.payment_status, o.order_status,
         o.created_at,
         (select coalesce(jsonb_agg(jsonb_build_object(
                   'product_id', oi.product_id, 'name', oi.product_name_snapshot,
                   'unit_price', oi.unit_price_snapshot, 'quantity', oi.quantity,
                   'line_total', oi.line_total) order by oi.created_at, oi.id), '[]'::jsonb)
          from public.order_items oi where oi.order_id = o.id)
  from public.orders o
  left join public.stores s on s.id = o.store_id
  where (p_status is null or o.order_status = p_status)
    and (   (v_role = 'customer' and o.customer_id = v_uid)
         or (v_role = 'seller' and s.owner_id = v_uid)
         or (v_role = 'driver' and o.driver_id = v_uid)
         or  v_role = 'admin')
  order by o.created_at desc, o.id desc
  limit p_limit offset p_offset;
end;
$$;
revoke all on function public.list_my_orders(public.order_status, integer, integer) from public, anon;
grant execute on function public.list_my_orders(public.order_status, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. create_order: idempotency, per-customer serialization, lock-then-validate
-- ---------------------------------------------------------------------------

alter table public.orders add column if not exists idempotency_key text;
alter table public.orders drop constraint if exists orders_idempotency_key_format;
alter table public.orders add constraint orders_idempotency_key_format
  check (idempotency_key is null or idempotency_key ~ '^[A-Za-z0-9_.:-]{8,100}$');
create unique index if not exists orders_customer_idempotency_key_uidx
  on public.orders(customer_id, idempotency_key) where idempotency_key is not null;

-- Replace the 7-argument version; the new 8-argument version keeps all previous
-- parameters, defaults and result columns, so existing named-argument callers keep working.
drop function if exists public.create_order(uuid, jsonb, text, numeric, numeric, text, public.payment_method);

create or replace function public.create_order(
  p_store_id uuid,
  p_items jsonb,
  p_delivery_address text,
  p_delivery_latitude numeric,
  p_delivery_longitude numeric,
  p_delivery_note text default null,
  p_payment_method public.payment_method default 'cod',
  p_idempotency_key text default null
)
returns table (
  order_id uuid,
  order_code text,
  subtotal numeric(12,2),
  delivery_fee numeric(12,2),
  total numeric(12,2),
  payment_method public.payment_method,
  payment_status public.payment_status,
  order_status public.order_status
)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_role public.app_role;
  v_store_fee numeric(12,2);
  v_radius numeric(8,2);
  v_store_lat numeric(9,6);
  v_store_lon numeric(9,6);
  v_distance_km double precision;
  v_item_count integer;
  v_bad_items boolean;
  v_subtotal numeric(12,2);
  v_total numeric(12,2);
  v_order_id uuid;
  v_order_code text;
  v_existing public.orders%rowtype;
  v_same_items boolean;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'authentication_required';
  end if;
  v_role := public.current_app_role();
  if v_role is distinct from 'customer' then
    raise exception using errcode = 'P0001', message = 'customer_role_required';
  end if;
  -- Transfer needs a verifier, proof flow and account details that are not decided
  -- and not implemented: always fail closed, even when the policy flag is set.
  if p_payment_method is distinct from 'cod' then
    raise exception using errcode = 'P0001', message = 'manual_transfer_not_configured';
  end if;
  if p_idempotency_key is not null and p_idempotency_key !~ '^[A-Za-z0-9_.:-]{8,100}$' then
    raise exception using errcode = 'P0001', message = 'invalid_idempotency_key';
  end if;
  if p_items is null or jsonb_typeof(p_items) is distinct from 'array' then
    raise exception using errcode = 'P0001', message = 'items_must_be_array';
  end if;
  v_item_count := jsonb_array_length(p_items);
  if v_item_count < 1 or v_item_count > 50 then
    raise exception using errcode = 'P0001', message = 'item_count_out_of_range';
  end if;
  if p_delivery_address is null or char_length(btrim(p_delivery_address)) not between 1 and 1500 then
    raise exception using errcode = 'P0001', message = 'delivery_address_required';
  end if;
  if p_delivery_note is not null and char_length(p_delivery_note) > 1000 then
    raise exception using errcode = 'P0001', message = 'delivery_note_too_long';
  end if;
  -- NaN and Infinity (numeric supports both) fail the range test as well; checked explicitly.
  if p_delivery_latitude is null or p_delivery_longitude is null
    or p_delivery_latitude in ('NaN', 'Infinity', '-Infinity')
    or p_delivery_longitude in ('NaN', 'Infinity', '-Infinity')
    or p_delivery_latitude not between -90 and 90
    or p_delivery_longitude not between -180 and 180 then
    raise exception using errcode = 'P0001', message = 'valid_delivery_coordinates_required';
  end if;
  -- Storage is numeric(9,6): round once so radius check, replay compare and insert agree.
  p_delivery_latitude := round(p_delivery_latitude, 6);
  p_delivery_longitude := round(p_delivery_longitude, 6);

  -- Serialize checkouts of the same customer (double-click / retry protection).
  perform pg_advisory_xact_lock(hashtextextended('create_order:' || v_user_id::text, 0));

  if p_idempotency_key is not null then
    select o.* into v_existing
    from public.orders o
    where o.customer_id = v_user_id and o.idempotency_key = p_idempotency_key;
    if found then
      if v_existing.store_id is distinct from p_store_id
        or v_existing.delivery_address is distinct from btrim(p_delivery_address)
        or v_existing.delivery_latitude is distinct from p_delivery_latitude
        or v_existing.delivery_longitude is distinct from p_delivery_longitude
        or v_existing.delivery_note is distinct from nullif(btrim(p_delivery_note), '') then
        raise exception using errcode = 'P0001', message = 'idempotency_key_conflict';
      end if;
      -- Items must match the stored order items (product and quantity); malformed items count as a mismatch.
      begin
        v_same_items := not exists (
          (select i.product_id, i.quantity
             from jsonb_to_recordset(p_items) as i(product_id uuid, quantity integer)
           except
           select oi.product_id, oi.quantity from public.order_items oi where oi.order_id = v_existing.id)
          union all
          (select oi.product_id, oi.quantity from public.order_items oi where oi.order_id = v_existing.id
           except
           select i.product_id, i.quantity
             from jsonb_to_recordset(p_items) as i(product_id uuid, quantity integer))
        ) and (select count(*) from jsonb_to_recordset(p_items) as i(product_id uuid, quantity integer))
              = (select count(*) from public.order_items oi where oi.order_id = v_existing.id);
      exception when others then
        v_same_items := false;
      end;
      if v_same_items is not true then
        raise exception using errcode = 'P0001', message = 'idempotency_key_conflict';
      end if;
      return query
      select o.id, o.order_code, o.subtotal, o.delivery_fee, o.total,
             o.payment_method, o.payment_status, o.order_status
      from public.orders o where o.id = v_existing.id;
      return;
    end if;
  end if;

  select s.delivery_fee, s.service_radius_km, s.latitude, s.longitude
    into v_store_fee, v_radius, v_store_lat, v_store_lon
  from public.stores s
  where s.id = p_store_id and s.is_active = true
  for share;
  if not found then
    raise exception using errcode = 'P0001', message = 'store_not_available';
  end if;
  -- NaN fee/radius (legacy or bypassed rows) count as not configured: NaN would make the total NaN
  -- and `distance > NaN` is false, which would silently skip the radius check.
  if v_store_fee is null or v_radius is null or v_store_lat is null or v_store_lon is null
     or v_store_fee = 'NaN'::numeric or v_store_fee < 0 or v_radius = 'NaN'::numeric or v_radius <= 0
     or v_store_lat = 'NaN'::numeric or v_store_lon = 'NaN'::numeric then
    raise exception using errcode = 'P0001', message = 'store_delivery_not_configured';
  end if;

  v_distance_km := public.haversine_km(v_store_lat, v_store_lon, p_delivery_latitude, p_delivery_longitude);
  if v_distance_km is null or v_distance_km = 'NaN'::double precision or v_distance_km > v_radius then
    raise exception using errcode = 'P0001', message = 'outside_store_service_radius';
  end if;

  begin
    select exists (
      select 1
      from jsonb_to_recordset(p_items) as i(product_id uuid, quantity integer)
      where i.product_id is null or i.quantity is null or i.quantity not between 1 and 99
    ) into v_bad_items;
  exception when invalid_text_representation or numeric_value_out_of_range
    or invalid_parameter_value or datatype_mismatch then
    v_bad_items := true;
  end;
  if v_bad_items then
    raise exception using errcode = 'P0001', message = 'invalid_order_item';
  end if;
  if exists (
    select i.product_id
    from jsonb_to_recordset(p_items) as i(product_id uuid, quantity integer)
    group by i.product_id having count(*) > 1
  ) then
    raise exception using errcode = 'P0001', message = 'duplicate_product_in_items';
  end if;

  -- Lock product rows first (stable order), then validate and snapshot: a concurrent
  -- price or availability change either happens before the lock or waits until commit.
  perform p.id
  from public.products p
  where p.id in (select i.product_id from jsonb_to_recordset(p_items) as i(product_id uuid, quantity integer))
  order by p.id
  for share of p;

  if exists (
    select 1
    from jsonb_to_recordset(p_items) as i(product_id uuid, quantity integer)
    left join public.products p on p.id = i.product_id
    where p.id is null or p.store_id <> p_store_id or p.is_available is not true
  ) then
    raise exception using errcode = 'P0001', message = 'product_unavailable_or_wrong_store';
  end if;

  -- Defense in depth for legacy/bypassed rows; the table constraint blocks new NaN prices.
  if exists (
    select 1
    from jsonb_to_recordset(p_items) as i(product_id uuid, quantity integer)
    join public.products p on p.id = i.product_id
    where p.store_id = p_store_id and p.is_available is true
      and p.price = 'NaN'::numeric
  ) then
    raise exception using errcode = 'P0001', message = 'invalid_product_price';
  end if;

  select sum(p.price * i.quantity)::numeric(12,2)
    into v_subtotal
  from jsonb_to_recordset(p_items) as i(product_id uuid, quantity integer)
  join public.products p on p.id = i.product_id
  where p.store_id = p_store_id and p.is_available = true;
  if v_subtotal is null then
    raise exception using errcode = 'P0001', message = 'order_subtotal_unavailable';
  end if;
  v_total := (v_subtotal + v_store_fee)::numeric(12,2);
  if v_subtotal = 'NaN'::numeric or v_total = 'NaN'::numeric or v_total < 0 then
    raise exception using errcode = 'P0001', message = 'order_subtotal_unavailable';
  end if;

  insert into public.orders as created_order (
    customer_id, store_id, delivery_address, delivery_latitude, delivery_longitude,
    delivery_note, subtotal, delivery_fee, total, payment_method, payment_status, order_status,
    idempotency_key
  ) values (
    v_user_id, p_store_id, btrim(p_delivery_address), p_delivery_latitude, p_delivery_longitude,
    nullif(btrim(p_delivery_note), ''), v_subtotal, v_store_fee, v_total,
    'cod', 'unpaid', 'pending_seller', p_idempotency_key
  ) returning created_order.id, created_order.order_code into v_order_id, v_order_code;

  insert into public.order_items (
    order_id, product_id, product_name_snapshot, unit_price_snapshot, quantity, line_total
  )
  select v_order_id, p.id, p.name, p.price, i.quantity, (p.price * i.quantity)::numeric(12,2)
  from jsonb_to_recordset(p_items) as i(product_id uuid, quantity integer)
  join public.products p on p.id = i.product_id
  where p.store_id = p_store_id and p.is_available = true;

  insert into public.order_status_history (order_id, old_status, new_status, changed_by, note)
  values (v_order_id, null, 'pending_seller', v_user_id, 'Order created');

  return query
  select o.id, o.order_code, o.subtotal, o.delivery_fee, o.total,
         o.payment_method, o.payment_status, o.order_status
  from public.orders o where o.id = v_order_id;
end;
$$;

revoke all on function public.create_order(uuid, jsonb, text, numeric, numeric, text, public.payment_method, text) from public, anon;
grant execute on function public.create_order(uuid, jsonb, text, numeric, numeric, text, public.payment_method, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. change_order_status: policy-driven completion/cancellation, driver guard
-- ---------------------------------------------------------------------------

create or replace function public.change_order_status(
  p_order_id uuid,
  p_new_status public.order_status,
  p_note text default null
)
returns public.order_status
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_order public.orders%rowtype;
  v_role public.app_role;
  v_is_store_owner boolean;
  v_completion_actor text;
  v_cancel_statuses text;
  v_allowed boolean := false;
  v_transition_valid boolean := false;
begin
  if auth.uid() is null then
    raise exception using errcode = 'P0001', message = 'authentication_required';
  end if;
  if p_note is not null and char_length(p_note) > 500 then
    raise exception using errcode = 'P0001', message = 'status_note_too_long';
  end if;
  select o.* into v_order from public.orders o where o.id = p_order_id for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'order_not_found';
  end if;
  v_role := public.current_app_role();
  v_is_store_owner := exists (
    select 1 from public.stores s where s.id = v_order.store_id and s.owner_id = auth.uid()
  );

  if p_new_status = 'cancelled' then
    -- Fail closed until operators approve a cancellation policy (stages, actors, refund).
    v_cancel_statuses := public.ops_policy_value('cancellation_allowed_statuses');
    if public.ops_policy_value('cancellation_enabled') is distinct from 'true'
       or nullif(btrim(coalesce(v_cancel_statuses, '')), '') is null then
      raise exception using errcode = 'P0001', message = 'cancellation_policy_not_configured';
    end if;
    if not (v_order.order_status::text = any (string_to_array(v_cancel_statuses, ','))) then
      raise exception using errcode = 'P0001', message = 'status_transition_not_allowed';
    end if;
    if nullif(btrim(p_note), '') is null then
      raise exception using errcode = 'P0001', message = 'cancellation_reason_required';
    end if;
    if not (v_role = 'admin'
            or (v_role = 'customer' and v_order.customer_id = auth.uid())
            or (v_role = 'seller' and v_is_store_owner)) then
      raise exception using errcode = 'P0001', message = 'status_transition_not_allowed';
    end if;
    -- Payment status is intentionally untouched: refunds are not decided.
    update public.orders set order_status = 'cancelled' where id = p_order_id;
    insert into public.order_status_history (order_id, old_status, new_status, changed_by, note)
    values (p_order_id, v_order.order_status, 'cancelled', auth.uid(), btrim(p_note));
    return p_new_status;
  end if;

  if p_new_status = 'rejected' and nullif(btrim(p_note), '') is null then
    raise exception using errcode = 'P0001', message = 'rejection_reason_required';
  end if;

  v_transition_valid :=
    (v_order.order_status = 'pending_seller' and p_new_status in ('accepted', 'rejected'))
    or (v_order.order_status = 'accepted' and p_new_status = 'preparing')
    or (v_order.order_status = 'preparing' and p_new_status = 'ready_for_pickup')
    or (v_order.order_status = 'ready_for_pickup' and p_new_status = 'picked_up')
    or (v_order.order_status = 'picked_up' and p_new_status = 'delivered')
    or (v_order.order_status = 'delivered' and p_new_status = 'completed');
  if not v_transition_valid then
    raise exception using errcode = 'P0001', message = 'status_transition_not_allowed';
  end if;

  v_completion_actor := coalesce(public.ops_policy_value('completion_actor'), 'customer');

  if v_role = 'admin' then
    v_allowed := true;
  elsif v_role = 'seller' and v_is_store_owner then
    v_allowed := (v_order.order_status = 'pending_seller' and p_new_status in ('accepted', 'rejected'))
      or (v_order.order_status = 'accepted' and p_new_status = 'preparing')
      or (v_order.order_status = 'preparing' and p_new_status = 'ready_for_pickup');
  elsif v_role = 'driver' and v_order.driver_id = auth.uid() then
    v_allowed := (v_order.order_status = 'ready_for_pickup' and p_new_status = 'picked_up')
      or (v_order.order_status = 'picked_up' and p_new_status = 'delivered');
  end if;
  -- Completion actor is operator-configured (default: customer).
  if not v_allowed and v_order.order_status = 'delivered' and p_new_status = 'completed' then
    v_allowed := (v_completion_actor = 'customer' and v_role = 'customer' and v_order.customer_id = auth.uid())
      or (v_completion_actor = 'seller' and v_role = 'seller' and v_is_store_owner)
      or (v_completion_actor = 'driver' and v_role = 'driver' and v_order.driver_id = auth.uid());
  end if;

  if not v_allowed then
    raise exception using errcode = 'P0001', message = 'status_transition_not_allowed';
  end if;
  if p_new_status = 'picked_up' and v_order.driver_id is null then
    raise exception using errcode = 'P0001', message = 'driver_not_assigned';
  end if;

  update public.orders set order_status = p_new_status where id = p_order_id;
  insert into public.order_status_history (order_id, old_status, new_status, changed_by, note)
  values (p_order_id, v_order.order_status, p_new_status, auth.uid(), nullif(btrim(p_note), ''));
  return p_new_status;
end;
$$;
revoke all on function public.change_order_status(uuid, public.order_status, text) from public, anon;
grant execute on function public.change_order_status(uuid, public.order_status, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. assign_order_driver: audit trail, no-op on same driver
-- ---------------------------------------------------------------------------

create or replace function public.assign_order_driver(
  p_order_id uuid,
  p_driver_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_order public.orders%rowtype;
begin
  if auth.uid() is null or public.current_app_role() is distinct from 'admin' then
    raise exception using errcode = 'P0001', message = 'admin_role_required';
  end if;
  if p_driver_id is null
     or not exists (select 1 from public.profiles p where p.id = p_driver_id and p.role = 'driver') then
    raise exception using errcode = 'P0001', message = 'driver_profile_required';
  end if;
  select o.* into v_order from public.orders o where o.id = p_order_id for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'order_not_found';
  end if;
  -- Assignment (and re-assignment) is only possible before pickup.
  if v_order.order_status not in ('accepted', 'preparing', 'ready_for_pickup') then
    raise exception using errcode = 'P0001', message = 'order_not_assignable';
  end if;
  if v_order.driver_id is not distinct from p_driver_id then
    return p_driver_id;
  end if;
  update public.orders set driver_id = p_driver_id where id = p_order_id;
  insert into public.order_status_history (order_id, old_status, new_status, changed_by, note)
  values (p_order_id, v_order.order_status, v_order.order_status, auth.uid(),
          case when v_order.driver_id is null then 'driver_assigned:' || p_driver_id::text
               else 'driver_reassigned:' || v_order.driver_id::text || '->' || p_driver_id::text end);
  insert into public.admin_audit_log (actor_id, action, target_type, target_id, details)
  values (auth.uid(), 'assign_order_driver', 'order', p_order_id::text,
          jsonb_build_object('driver_id', p_driver_id, 'previous_driver_id', v_order.driver_id));
  return p_driver_id;
end;
$$;
revoke all on function public.assign_order_driver(uuid, uuid) from public, anon;
grant execute on function public.assign_order_driver(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 9. COD collection recording (explicit action, fail closed until approved)
-- ---------------------------------------------------------------------------

create or replace function public.record_cod_collection(
  p_order_id uuid,
  p_note text default null
)
returns public.payment_status
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_order public.orders%rowtype;
  v_role public.app_role;
  v_actor text;
begin
  if auth.uid() is null then
    raise exception using errcode = 'P0001', message = 'authentication_required';
  end if;
  if public.ops_policy_value('cod_collection_recording_enabled') is distinct from 'true'
     or public.ops_policy_value('cod_collection_actor') is null then
    raise exception using errcode = 'P0001', message = 'cod_collection_policy_not_configured';
  end if;
  if p_note is not null and char_length(p_note) > 500 then
    raise exception using errcode = 'P0001', message = 'status_note_too_long';
  end if;
  select o.* into v_order from public.orders o where o.id = p_order_id for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'order_not_found';
  end if;
  v_role := public.current_app_role();
  v_actor := public.ops_policy_value('cod_collection_actor');
  if not (v_role = 'admin' or (v_role = 'driver' and v_actor = 'driver' and v_order.driver_id = auth.uid())) then
    raise exception using errcode = 'P0001', message = 'status_transition_not_allowed';
  end if;
  if v_order.payment_method is distinct from 'cod' then
    raise exception using errcode = 'P0001', message = 'order_not_cod';
  end if;
  if v_order.order_status not in ('delivered', 'completed') then
    raise exception using errcode = 'P0001', message = 'order_not_delivered';
  end if;
  if v_order.payment_status is distinct from 'unpaid' then
    raise exception using errcode = 'P0001', message = 'payment_already_recorded';
  end if;
  update public.orders set payment_status = 'verified' where id = p_order_id;
  insert into public.order_status_history (order_id, old_status, new_status, changed_by, note)
  values (p_order_id, v_order.order_status, v_order.order_status, auth.uid(),
          'cod_collected' || coalesce(': ' || nullif(btrim(p_note), ''), ''));
  return 'verified';
end;
$$;
revoke all on function public.record_cod_collection(uuid, text) from public, anon;
grant execute on function public.record_cod_collection(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 10. Admin operations (admin-only RPC, audited)
-- ---------------------------------------------------------------------------

create or replace function public.admin_set_store_active(p_store_id uuid, p_active boolean)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if auth.uid() is null or public.current_app_role() is distinct from 'admin' then
    raise exception using errcode = 'P0001', message = 'admin_role_required';
  end if;
  if p_active is null then
    raise exception using errcode = 'P0001', message = 'invalid_argument';
  end if;
  update public.stores set is_active = p_active where id = p_store_id;
  if not found then
    raise exception using errcode = 'P0001', message = 'store_not_found';
  end if;
  insert into public.admin_audit_log (actor_id, action, target_type, target_id, details)
  values (auth.uid(), 'set_store_active', 'store', p_store_id::text, jsonb_build_object('is_active', p_active));
  return p_active;
end;
$$;

create or replace function public.admin_set_store_delivery_config(
  p_store_id uuid,
  p_delivery_fee numeric,
  p_service_radius_km numeric,
  p_latitude numeric default null,
  p_longitude numeric default null
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_store public.stores%rowtype;
  v_lat numeric;
  v_lon numeric;
begin
  if auth.uid() is null or public.current_app_role() is distinct from 'admin' then
    raise exception using errcode = 'P0001', message = 'admin_role_required';
  end if;
  if p_delivery_fee is null or p_delivery_fee < 0 or p_delivery_fee in ('NaN', 'Infinity')
     or p_service_radius_km is null or p_service_radius_km <= 0 or p_service_radius_km in ('NaN', 'Infinity') then
    raise exception using errcode = 'P0001', message = 'invalid_delivery_config';
  end if;
  if (p_latitude is null) <> (p_longitude is null) then
    raise exception using errcode = 'P0001', message = 'valid_coordinates_required';
  end if;
  select s.* into v_store from public.stores s where s.id = p_store_id for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'store_not_found';
  end if;
  v_lat := coalesce(p_latitude, v_store.latitude);
  v_lon := coalesce(p_longitude, v_store.longitude);
  if v_lat is null or v_lon is null or v_lat not between -90 and 90 or v_lon not between -180 and 180 then
    raise exception using errcode = 'P0001', message = 'valid_coordinates_required';
  end if;
  update public.stores
     set delivery_fee = p_delivery_fee, service_radius_km = p_service_radius_km,
         latitude = v_lat, longitude = v_lon
   where id = p_store_id;
  insert into public.admin_audit_log (actor_id, action, target_type, target_id, details)
  values (auth.uid(), 'set_store_delivery_config', 'store', p_store_id::text,
          jsonb_build_object('delivery_fee', p_delivery_fee, 'service_radius_km', p_service_radius_km,
                             'latitude', v_lat, 'longitude', v_lon));
end;
$$;

create or replace function public.admin_set_product_available(p_product_id uuid, p_available boolean)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if auth.uid() is null or public.current_app_role() is distinct from 'admin' then
    raise exception using errcode = 'P0001', message = 'admin_role_required';
  end if;
  if p_available is null then
    raise exception using errcode = 'P0001', message = 'invalid_argument';
  end if;
  update public.products set is_available = p_available where id = p_product_id;
  if not found then
    raise exception using errcode = 'P0001', message = 'product_not_found';
  end if;
  insert into public.admin_audit_log (actor_id, action, target_type, target_id, details)
  values (auth.uid(), 'set_product_available', 'product', p_product_id::text,
          jsonb_build_object('is_available', p_available));
  return p_available;
end;
$$;

create or replace function public.admin_get_policies()
returns table (key text, value text)
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
begin
  if auth.uid() is null or public.current_app_role() is distinct from 'admin' then
    raise exception using errcode = 'P0001', message = 'admin_role_required';
  end if;
  return query select p.key, p.value from public.ops_policy p order by p.key;
end;
$$;

revoke all on function public.admin_set_store_active(uuid, boolean) from public, anon;
grant execute on function public.admin_set_store_active(uuid, boolean) to authenticated;
revoke all on function public.admin_set_store_delivery_config(uuid, numeric, numeric, numeric, numeric) from public, anon;
grant execute on function public.admin_set_store_delivery_config(uuid, numeric, numeric, numeric, numeric) to authenticated;
revoke all on function public.admin_set_product_available(uuid, boolean) from public, anon;
grant execute on function public.admin_set_product_available(uuid, boolean) to authenticated;
revoke all on function public.admin_get_policies() from public, anon;
grant execute on function public.admin_get_policies() to authenticated;

-- ---------------------------------------------------------------------------
-- 11. Trusted provisioning (service_role / postgres only; never from the frontend)
-- ---------------------------------------------------------------------------

-- Run from the Supabase SQL editor, CLI or a CI secret. Example:
--   select public.provision_set_user_role('<user uuid>', 'admin', 'initial admin');
create or replace function public.provision_set_user_role(
  p_user_id uuid,
  p_role public.app_role,
  p_reason text default null
)
returns public.app_role
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_old public.app_role;
begin
  select p.role into v_old from public.profiles p where p.id = p_user_id for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'profile_not_found';
  end if;
  update public.profiles set role = p_role where id = p_user_id;
  insert into public.admin_audit_log (actor_id, action, target_type, target_id, details)
  values (null, 'provision_set_user_role', 'profile', p_user_id::text,
          jsonb_build_object('old_role', v_old, 'new_role', p_role, 'reason', p_reason,
                             'db_user', session_user));
  return p_role;
end;
$$;

create or replace function public.provision_set_policy(p_key text, p_value text)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_status text;
begin
  if p_value is null then
    raise exception using errcode = 'P0001', message = 'invalid_policy_value';
  end if;
  case p_key
    when 'completion_actor' then
      if p_value not in ('customer', 'seller', 'driver') then
        raise exception using errcode = 'P0001', message = 'invalid_policy_value';
      end if;
    when 'cancellation_enabled', 'manual_transfer_enabled', 'cod_collection_recording_enabled' then
      if p_value not in ('true', 'false') then
        raise exception using errcode = 'P0001', message = 'invalid_policy_value';
      end if;
    when 'cancellation_allowed_statuses' then
      -- Comma separated, only non-terminal statuses.
      for v_status in select btrim(x) from unnest(string_to_array(p_value, ',')) as x loop
        if v_status not in ('pending_seller', 'accepted', 'preparing', 'ready_for_pickup') then
          raise exception using errcode = 'P0001', message = 'invalid_policy_value';
        end if;
      end loop;
    when 'cod_collection_actor' then
      if p_value not in ('driver', 'admin') then
        raise exception using errcode = 'P0001', message = 'invalid_policy_value';
      end if;
    else
      raise exception using errcode = 'P0001', message = 'unknown_policy_key';
  end case;
  insert into public.ops_policy (key, value) values (p_key, replace(p_value, ' ', ''))
  on conflict (key) do update set value = excluded.value, updated_at = now();
  insert into public.admin_audit_log (actor_id, action, target_type, target_id, details)
  values (null, 'provision_set_policy', 'ops_policy', p_key,
          jsonb_build_object('value', p_value, 'db_user', session_user));
end;
$$;

revoke all on function public.provision_set_user_role(uuid, public.app_role, text) from public, anon, authenticated;
grant execute on function public.provision_set_user_role(uuid, public.app_role, text) to service_role;
revoke all on function public.provision_set_policy(text, text) from public, anon, authenticated;
grant execute on function public.provision_set_policy(text, text) to service_role;

comment on table public.ops_policy is 'Operational policy flags. Writable only through provision_set_policy (service_role/postgres). Fail-closed defaults.';
comment on function public.provision_set_user_role(uuid, public.app_role, text) is 'Trusted-only role provisioning (service_role/postgres). Not callable by anon/authenticated.';
comment on function public.record_cod_collection(uuid, text) is 'Explicit COD collection record; fails closed until cod_collection policy is configured. Delivered/completed never implies paid.';

commit;
