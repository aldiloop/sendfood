-- SendFood: rumus ongkir per jarak + batas radius 5 km (keputusan pemilik 12 Nov 2026)
-- Applies on top of 20261108000000_sendfood_backend_mvp_hardening.sql (do not edit that file).
--
-- Sebelumnya create_order memakai ongkir tetap per toko (stores.delivery_fee, wajib
-- non-null) dan jarak Haversine hanya dipakai untuk cek radius. Rumus baru (wajib persis):
-- * jarak <= 1000 m -> ongkir Rp2.000 flat.
-- * jarak > 1000 m -> ongkir = 2000 + ceil((jarak_m - 1000) / 100) * 200.
--   Contoh pemilik: 2350 m -> Rp4.800.
-- * Jarak dihitung dalam meter bilangan bulat (round dari Haversine km x 1000) agar tidak
--   ada galat float di batas; ongkir numeric eksak.
-- * Ongkir tetap dikunci di orders.delivery_fee saat checkout.
-- * Kolom stores.delivery_fee DIPERTAHANKAN (tidak di-drop), tetapi create_order TIDAK
--   LAGI mewajibkan atau membacanya (hanya radius + koordinat yang wajib). Kolom itu
--   kini hanya tampil di katalog; harga checkout memakai rumus jarak.
-- * Batas radius: check constraint stores.service_radius_km <= 5. Cek radius di checkout tetap.
--
-- Atomic and fail-fast: the whole file is one explicit transaction
-- (BEGIN ... COMMIT), so a failure anywhere rolls back schema, catalog and data even when run
-- with plain `psql -f` or pasted into an SQL editor. Always use ON_ERROR_STOP with psql.
-- lock_timeout makes it fail instead of queueing behind long-held locks on a live database.

begin;
set local lock_timeout = '5s';
set local statement_timeout = '120s';

do $$
begin
  if to_regprocedure('public.create_order(uuid, jsonb, text, numeric, numeric, text, public.payment_method, text)') is null
     or to_regprocedure('public.haversine_km(numeric, numeric, numeric, numeric)') is null then
    raise exception using errcode = 'P0001', message = 'distance_fee_requires_hardening_migration';
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- 1. Rumus ongkir per jarak (pure function, bisa diuji langsung)
-- ---------------------------------------------------------------------------

create or replace function public.delivery_fee_for_distance(p_distance_m integer)
returns numeric(12,2)
language plpgsql
immutable
set search_path = pg_catalog, public
as $$
begin
  if p_distance_m is null or p_distance_m < 0 then
    raise exception using errcode = 'P0001', message = 'invalid_distance';
  end if;
  if p_distance_m <= 1000 then
    return 2000::numeric(12,2);
  end if;
  return (2000 + ceil((p_distance_m - 1000)::numeric / 100) * 200)::numeric(12,2);
end;
$$;
revoke all on function public.delivery_fee_for_distance(integer) from public, anon, authenticated;
comment on function public.delivery_fee_for_distance(integer) is 'Distance-based delivery fee (owner decision 2026-11-12): <=1000 m flat Rp2000; above that 2000 + ceil((m-1000)/100)*200. Exact numeric; distance in whole meters.';

-- ---------------------------------------------------------------------------
-- 2. Batas radius layanan: maksimal 5 km
-- ---------------------------------------------------------------------------

alter table public.stores add constraint stores_service_radius_max_5km
  check (service_radius_km is null or service_radius_km <= 5);

-- ---------------------------------------------------------------------------
-- 3. create_order: ongkir dari rumus jarak, bukan dari stores.delivery_fee
--    (seluruh logika lain tidak berubah dari migrasi hardening)
-- ---------------------------------------------------------------------------

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
  v_radius numeric(8,2);
  v_store_lat numeric(9,6);
  v_store_lon numeric(9,6);
  v_distance_km double precision;
  v_distance_m integer;
  v_delivery_fee numeric(12,2);
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

  select s.service_radius_km, s.latitude, s.longitude
    into v_radius, v_store_lat, v_store_lon
  from public.stores s
  where s.id = p_store_id and s.is_active = true
  for share;
  if not found then
    raise exception using errcode = 'P0001', message = 'store_not_available';
  end if;
  -- NaN radius/coords (legacy or bypassed rows) count as not configured: a NaN
  -- radius would make `distance > NaN` false and silently skip the radius check.
  -- stores.delivery_fee is no longer read here: the fee comes from the distance
  -- formula (delivery_fee_for_distance), so a missing/NaN store fee does not block checkout.
  if v_radius is null or v_store_lat is null or v_store_lon is null
     or v_radius = 'NaN'::numeric or v_radius <= 0
     or v_store_lat = 'NaN'::numeric or v_store_lon = 'NaN'::numeric then
    raise exception using errcode = 'P0001', message = 'store_delivery_not_configured';
  end if;

  v_distance_km := public.haversine_km(v_store_lat, v_store_lon, p_delivery_latitude, p_delivery_longitude);
  if v_distance_km is null or v_distance_km = 'NaN'::double precision or v_distance_km > v_radius then
    raise exception using errcode = 'P0001', message = 'outside_store_service_radius';
  end if;

  -- Distance-based fee (owner decision 2026-11-12): whole meters, rounded from
  -- Haversine km, so there is no float error at the 1000 m boundary.
  v_distance_m := round(v_distance_km * 1000)::integer;
  v_delivery_fee := public.delivery_fee_for_distance(v_distance_m);

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
  v_total := (v_subtotal + v_delivery_fee)::numeric(12,2);
  if v_subtotal = 'NaN'::numeric or v_delivery_fee = 'NaN'::numeric or v_total = 'NaN'::numeric or v_total < 0 then
    raise exception using errcode = 'P0001', message = 'order_subtotal_unavailable';
  end if;

  insert into public.orders as created_order (
    customer_id, store_id, delivery_address, delivery_latitude, delivery_longitude,
    delivery_note, subtotal, delivery_fee, total, payment_method, payment_status, order_status,
    idempotency_key
  ) values (
    v_user_id, p_store_id, btrim(p_delivery_address), p_delivery_latitude, p_delivery_longitude,
    nullif(btrim(p_delivery_note), ''), v_subtotal, v_delivery_fee, v_total,
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
-- 4. Komentar kolom: delivery_fee dipertahankan tapi bukan lagi harga checkout;
--    radius maksimal 5 km (keputusan pemilik 12 Nov 2026)
-- ---------------------------------------------------------------------------

comment on column public.stores.delivery_fee is 'Retained for catalog display and legacy rows. Checkout pricing no longer uses it: create_order charges the distance formula (delivery_fee_for_distance).';
comment on column public.stores.service_radius_km is 'Required for checkout; straight-line Haversine enforcement. Maximum 5 km (owner decision 2026-11-12, constraint stores_service_radius_max_5km).';

commit;
