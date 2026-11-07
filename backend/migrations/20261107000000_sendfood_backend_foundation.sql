-- SendFood backend foundation — v1
-- Draft-safe operating gates:
-- * checkout accepts COD only until manual-transfer verification is agreed;
-- * checkout is rejected until each store has an explicit flat delivery fee,
--   service radius, and coordinates configured by a trusted operator;
-- * radius uses straight-line Haversine distance as a provisional MVP rule;
-- * only admin can assign drivers; cancellation remains disabled pending policy.

create type public.app_role as enum ('customer', 'seller', 'driver', 'admin');
create type public.payment_method as enum ('cod', 'manual_transfer');
create type public.payment_status as enum ('unpaid', 'pending_verification', 'verified', 'failed');
create type public.order_status as enum (
  'pending_seller', 'accepted', 'rejected', 'preparing',
  'ready_for_pickup', 'picked_up', 'delivered', 'completed', 'cancelled'
);

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  phone text,
  role public.app_role not null default 'customer',
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_full_name_length check (full_name is null or char_length(full_name) <= 160),
  constraint profiles_phone_length check (phone is null or char_length(phone) <= 40)
);

create table public.stores (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete restrict,
  name text not null check (char_length(btrim(name)) between 1 and 160),
  description text,
  address text not null check (char_length(btrim(address)) between 1 and 1000),
  latitude numeric(9,6),
  longitude numeric(9,6),
  phone text,
  image_url text,
  is_active boolean not null default false,
  opening_hours jsonb,
  -- NULL means not yet configured; checkout fails closed until configured.
  delivery_fee numeric(12,2),
  service_radius_km numeric(8,2),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint stores_latitude_range check (latitude is null or latitude between -90 and 90),
  constraint stores_longitude_range check (longitude is null or longitude between -180 and 180),
  constraint stores_coordinate_pair check ((latitude is null) = (longitude is null)),
  constraint stores_delivery_fee_nonnegative check (delivery_fee is null or delivery_fee >= 0),
  constraint stores_radius_nonnegative check (service_radius_km is null or service_radius_km >= 0),
  constraint stores_radius_requires_coordinates check (service_radius_km is null or latitude is not null)
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 160),
  description text,
  price numeric(12,2) not null check (price >= 0),
  image_url text,
  is_available boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  order_code text not null unique default (
    'SF-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10))
  ),
  customer_id uuid not null references public.profiles(id) on delete restrict,
  store_id uuid not null references public.stores(id) on delete restrict,
  driver_id uuid references public.profiles(id) on delete restrict,
  delivery_address text not null check (char_length(btrim(delivery_address)) between 1 and 1500),
  delivery_latitude numeric(9,6),
  delivery_longitude numeric(9,6),
  delivery_note text,
  subtotal numeric(12,2) not null check (subtotal >= 0),
  delivery_fee numeric(12,2) not null check (delivery_fee >= 0),
  total numeric(12,2) not null check (total >= 0 and total = subtotal + delivery_fee),
  payment_method public.payment_method not null,
  payment_status public.payment_status not null default 'unpaid',
  order_status public.order_status not null default 'pending_seller',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint orders_coordinate_pair check ((delivery_latitude is null) = (delivery_longitude is null)),
  constraint orders_latitude_range check (delivery_latitude is null or delivery_latitude between -90 and 90),
  constraint orders_longitude_range check (delivery_longitude is null or delivery_longitude between -180 and 180),
  constraint orders_delivery_note_length check (delivery_note is null or char_length(delivery_note) <= 1000)
);

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  product_name_snapshot text not null,
  unit_price_snapshot numeric(12,2) not null check (unit_price_snapshot >= 0),
  quantity integer not null check (quantity between 1 and 99),
  line_total numeric(12,2) not null check (line_total >= 0),
  created_at timestamptz not null default now()
);

create table public.order_status_history (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  old_status public.order_status,
  new_status public.order_status not null,
  changed_by uuid references public.profiles(id) on delete set null,
  note text,
  created_at timestamptz not null default now()
);

create index stores_owner_id_idx on public.stores(owner_id);
create index stores_active_idx on public.stores(is_active);
create index products_store_id_idx on public.products(store_id);
create index products_available_idx on public.products(is_available);
create index orders_customer_created_idx on public.orders(customer_id, created_at desc);
create index orders_store_status_created_idx on public.orders(store_id, order_status, created_at desc);
create index orders_driver_status_idx on public.orders(driver_id, order_status);
create index order_items_order_id_idx on public.order_items(order_id);
create index order_status_history_order_created_idx on public.order_status_history(order_id, created_at);

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger profiles_touch_updated_at before update on public.profiles
for each row execute function public.touch_updated_at();
create trigger stores_touch_updated_at before update on public.stores
for each row execute function public.touch_updated_at();
create trigger products_touch_updated_at before update on public.products
for each row execute function public.touch_updated_at();
create trigger orders_touch_updated_at before update on public.orders
for each row execute function public.touch_updated_at();

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  insert into public.profiles (id, full_name, phone, role)
  values (
    new.id,
    nullif(coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name'), ''),
    nullif(new.raw_user_meta_data ->> 'phone', ''),
    'customer'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();

create or replace function public.current_app_role()
returns public.app_role
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select p.role from public.profiles p where p.id = auth.uid()
$$;

alter table public.profiles enable row level security;
alter table public.stores enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.order_status_history enable row level security;

create policy profiles_select_self_or_admin on public.profiles
  for select to authenticated
  using (id = auth.uid() or public.current_app_role() = 'admin');
create policy profiles_update_self on public.profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

create policy stores_public_active_read on public.stores
  for select to anon using (is_active = true);
create policy stores_authenticated_read on public.stores
  for select to authenticated
  using (is_active = true or owner_id = auth.uid() or public.current_app_role() = 'admin');
create policy stores_seller_insert_own on public.stores
  for insert to authenticated
  with check (owner_id = auth.uid() and public.current_app_role() = 'seller');
create policy stores_seller_update_own on public.stores
  for update to authenticated
  using (owner_id = auth.uid() and public.current_app_role() = 'seller')
  with check (owner_id = auth.uid() and public.current_app_role() = 'seller');

create policy products_public_available_read on public.products
  for select to anon
  using (is_available = true and exists (
    select 1 from public.stores s where s.id = store_id and s.is_active = true
  ));
create policy products_authenticated_read on public.products
  for select to authenticated
  using (
    (is_available = true and exists (
      select 1 from public.stores s where s.id = store_id and s.is_active = true
    ))
    or exists (
      select 1 from public.stores s where s.id = store_id and s.owner_id = auth.uid()
    )
    or public.current_app_role() = 'admin'
  );
create policy products_seller_insert_own on public.products
  for insert to authenticated
  with check (
    public.current_app_role() = 'seller'
    and exists (select 1 from public.stores s where s.id = store_id and s.owner_id = auth.uid())
  );
create policy products_seller_update_own on public.products
  for update to authenticated
  using (
    public.current_app_role() = 'seller'
    and exists (select 1 from public.stores s where s.id = store_id and s.owner_id = auth.uid())
  )
  with check (
    public.current_app_role() = 'seller'
    and exists (select 1 from public.stores s where s.id = store_id and s.owner_id = auth.uid())
  );
create policy products_seller_delete_own on public.products
  for delete to authenticated
  using (
    public.current_app_role() = 'seller'
    and exists (select 1 from public.stores s where s.id = store_id and s.owner_id = auth.uid())
  );

create policy orders_participant_read on public.orders
  for select to authenticated
  using (
    customer_id = auth.uid()
    or driver_id = auth.uid()
    or public.current_app_role() = 'admin'
    or exists (select 1 from public.stores s where s.id = store_id and s.owner_id = auth.uid())
  );
create policy order_items_participant_read on public.order_items
  for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_id));
create policy order_status_history_participant_read on public.order_status_history
  for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_id));

revoke all on table public.profiles, public.stores, public.products, public.orders,
  public.order_items, public.order_status_history from anon, authenticated;
grant select on public.profiles to authenticated;
grant update (full_name, phone, avatar_url) on public.profiles to authenticated;
grant select on public.stores to anon, authenticated;
grant insert (owner_id, name, description, address, latitude, longitude, phone, image_url, opening_hours)
  on public.stores to authenticated;
grant update (name, description, address, latitude, longitude, phone, image_url, opening_hours)
  on public.stores to authenticated;
grant select on public.products to anon, authenticated;
grant insert, update, delete on public.products to authenticated;
grant select on public.orders, public.order_items, public.order_status_history to authenticated;

create or replace function public.create_order(
  p_store_id uuid,
  p_items jsonb,
  p_delivery_address text,
  p_delivery_latitude numeric,
  p_delivery_longitude numeric,
  p_delivery_note text default null,
  p_payment_method public.payment_method default 'cod'
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
  v_distance_component double precision;
  v_distance_km double precision;
  v_item_count integer;
  v_subtotal numeric(12,2);
  v_total numeric(12,2);
  v_order_id uuid;
  v_order_code text;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'authentication_required';
  end if;
  v_role := public.current_app_role();
  if v_role is distinct from 'customer' then
    raise exception using errcode = 'P0001', message = 'customer_role_required';
  end if;
  if p_payment_method is distinct from 'cod' then
    raise exception using errcode = 'P0001', message = 'manual_transfer_not_configured';
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
  if p_delivery_latitude is null or p_delivery_longitude is null
    or p_delivery_latitude not between -90 and 90
    or p_delivery_longitude not between -180 and 180 then
    raise exception using errcode = 'P0001', message = 'valid_delivery_coordinates_required';
  end if;

  select s.delivery_fee, s.service_radius_km, s.latitude, s.longitude
    into v_store_fee, v_radius, v_store_lat, v_store_lon
  from public.stores s
  where s.id = p_store_id and s.is_active = true
  for share;
  if not found then
    raise exception using errcode = 'P0001', message = 'store_not_available';
  end if;
  if v_store_fee is null or v_radius is null or v_store_lat is null or v_store_lon is null then
    raise exception using errcode = 'P0001', message = 'store_delivery_not_configured';
  end if;

  v_distance_component :=
    power(sin(radians((p_delivery_latitude - v_store_lat)::double precision) / 2), 2)
    + cos(radians(v_store_lat::double precision))
      * cos(radians(p_delivery_latitude::double precision))
      * power(sin(radians((p_delivery_longitude - v_store_lon)::double precision) / 2), 2);
  v_distance_km := 2 * 6371.0088 * asin(sqrt(least(1.0, greatest(0.0, v_distance_component))));
  if v_distance_km > v_radius then
    raise exception using errcode = 'P0001', message = 'outside_store_service_radius';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_items) as i(product_id uuid, quantity integer)
    where i.product_id is null or i.quantity is null or i.quantity not between 1 and 99
  ) then
    raise exception using errcode = 'P0001', message = 'invalid_order_item';
  end if;
  if exists (
    select i.product_id
    from jsonb_to_recordset(p_items) as i(product_id uuid, quantity integer)
    group by i.product_id having count(*) > 1
  ) then
    raise exception using errcode = 'P0001', message = 'duplicate_product_in_items';
  end if;
  if exists (
    select 1
    from jsonb_to_recordset(p_items) as i(product_id uuid, quantity integer)
    left join public.products p on p.id = i.product_id
    where p.id is null or p.store_id <> p_store_id or p.is_available is not true
  ) then
    raise exception using errcode = 'P0001', message = 'product_unavailable_or_wrong_store';
  end if;

  -- Lock product rows while taking the trusted price snapshot.
  perform p.id
  from public.products p
  join jsonb_to_recordset(p_items) as i(product_id uuid, quantity integer) on i.product_id = p.id
  for share of p;

  select sum(p.price * i.quantity)::numeric(12,2)
    into v_subtotal
  from jsonb_to_recordset(p_items) as i(product_id uuid, quantity integer)
  join public.products p on p.id = i.product_id
  where p.store_id = p_store_id and p.is_available = true;
  if v_subtotal is null then
    raise exception using errcode = 'P0001', message = 'order_subtotal_unavailable';
  end if;
  v_total := (v_subtotal + v_store_fee)::numeric(12,2);

  insert into public.orders as created_order (
    customer_id, store_id, delivery_address, delivery_latitude, delivery_longitude,
    delivery_note, subtotal, delivery_fee, total, payment_method, payment_status, order_status
  ) values (
    v_user_id, p_store_id, btrim(p_delivery_address), p_delivery_latitude, p_delivery_longitude,
    nullif(btrim(p_delivery_note), ''), v_subtotal, v_store_fee, v_total,
    'cod', 'unpaid', 'pending_seller'
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
  if p_new_status = 'cancelled' then
    raise exception using errcode = 'P0001', message = 'cancellation_policy_not_configured';
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

  if v_role = 'admin' then
    v_allowed := true;
  elsif v_role = 'seller' and exists (
    select 1 from public.stores s where s.id = v_order.store_id and s.owner_id = auth.uid()
  ) then
    v_allowed := (v_order.order_status = 'pending_seller' and p_new_status in ('accepted', 'rejected'))
      or (v_order.order_status = 'accepted' and p_new_status = 'preparing')
      or (v_order.order_status = 'preparing' and p_new_status = 'ready_for_pickup');
  elsif v_role = 'driver' and v_order.driver_id = auth.uid() then
    v_allowed := (v_order.order_status = 'ready_for_pickup' and p_new_status = 'picked_up')
      or (v_order.order_status = 'picked_up' and p_new_status = 'delivered');
  elsif v_role = 'customer' and v_order.customer_id = auth.uid() then
    -- Provisional completion convention: customer confirms receipt after delivery.
    v_allowed := v_order.order_status = 'delivered' and p_new_status = 'completed';
  end if;

  if not v_allowed then
    raise exception using errcode = 'P0001', message = 'status_transition_not_allowed';
  end if;
  if p_new_status = v_order.order_status then
    raise exception using errcode = 'P0001', message = 'status_unchanged';
  end if;

  update public.orders set order_status = p_new_status where id = p_order_id;
  insert into public.order_status_history (order_id, old_status, new_status, changed_by, note)
  values (p_order_id, v_order.order_status, p_new_status, auth.uid(), nullif(btrim(p_note), ''));
  return p_new_status;
end;
$$;

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
  if not exists (select 1 from public.profiles p where p.id = p_driver_id and p.role = 'driver') then
    raise exception using errcode = 'P0001', message = 'driver_profile_required';
  end if;
  select o.* into v_order from public.orders o where o.id = p_order_id for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'order_not_found';
  end if;
  if v_order.order_status not in ('accepted', 'preparing', 'ready_for_pickup') then
    raise exception using errcode = 'P0001', message = 'order_not_assignable';
  end if;
  update public.orders set driver_id = p_driver_id where id = p_order_id;
  return p_driver_id;
end;
$$;

revoke all on function public.current_app_role() from public, anon;
grant execute on function public.current_app_role() to authenticated;
revoke all on function public.handle_new_auth_user() from public, anon, authenticated;
revoke all on function public.touch_updated_at() from public, anon, authenticated;
revoke all on function public.create_order(uuid, jsonb, text, numeric, numeric, text, public.payment_method) from public, anon;
grant execute on function public.create_order(uuid, jsonb, text, numeric, numeric, text, public.payment_method) to authenticated;
revoke all on function public.change_order_status(uuid, public.order_status, text) from public, anon;
grant execute on function public.change_order_status(uuid, public.order_status, text) to authenticated;
revoke all on function public.assign_order_driver(uuid, uuid) from public, anon;
grant execute on function public.assign_order_driver(uuid, uuid) to authenticated;

comment on column public.stores.delivery_fee is 'Required for checkout; per-store fixed fee is a provisional MVP configuration and must be reviewed before pilot.';
comment on column public.stores.service_radius_km is 'Required for checkout; straight-line Haversine enforcement is a provisional MVP assumption.';
comment on function public.assign_order_driver(uuid, uuid) is 'Temporary admin-only assignment fallback pending final driver-assignment policy.';
