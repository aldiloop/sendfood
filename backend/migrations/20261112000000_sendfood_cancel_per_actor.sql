-- SendFood: pembatalan per aktor (keputusan pemilik 12 Nov 2026)
-- Applies on top of 20261108000000_sendfood_backend_mvp_hardening.sql (do not edit that file).
--
-- Sebelumnya change_order_status (jalur cancelled) memakai satu daftar
-- `cancellation_allowed_statuses` yang berlaku untuk SEMUA aktor. Aturan baru:
-- * Master switch `cancellation_enabled` harus 'true'.
-- * Customer: batal hanya dari pending_seller (kunci `cancellation_allowed_statuses`).
-- * Seller (pemilik toko): batal dari pending_seller, accepted, preparing
--   (kunci BARU `cancellation_allowed_statuses_seller`); TIDAK boleh setelah preparing.
-- * Admin: batal dari status MANA PUN (melewati cek daftar status sepenuhnya).
-- * Alasan (p_note) tetap wajib untuk semua; payment_status tidak disentuh saat batal.
-- Seed (upsert): cancellation_enabled='true',
--   cancellation_allowed_statuses='pending_seller',
--   cancellation_allowed_statuses_seller='pending_seller,accepted,preparing'.
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
  if to_regclass('public.ops_policy') is null
     or to_regprocedure('public.provision_set_policy(text, text)') is null
     or to_regprocedure('public.change_order_status(uuid, public.order_status, text)') is null then
    raise exception using errcode = 'P0001', message = 'cancel_per_actor_requires_hardening_migration';
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- 1. Kunci kebijakan baru: cancellation_allowed_statuses_seller
--    (validasi sama dengan cancellation_allowed_statuses: daftar dipisah koma,
--    hanya status non-terminal)
-- ---------------------------------------------------------------------------

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
    when 'cancellation_allowed_statuses', 'cancellation_allowed_statuses_seller' then
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

revoke all on function public.provision_set_policy(text, text) from public, anon, authenticated;
grant execute on function public.provision_set_policy(text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 2. change_order_status: jalur cancelled per aktor
--    (bagian lain fungsi tidak berubah dari migrasi hardening)
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
    -- Master switch: cancellation is off until operators enable it.
    if public.ops_policy_value('cancellation_enabled') is distinct from 'true' then
      raise exception using errcode = 'P0001', message = 'cancellation_policy_not_configured';
    end if;
    -- Per-actor status lists. Admin bypasses the list entirely (any status).
    -- Customer uses cancellation_allowed_statuses; seller uses
    -- cancellation_allowed_statuses_seller. Other actors may not cancel at all.
    if v_role = 'admin' then
      v_cancel_statuses := null;
    elsif v_role = 'customer' and v_order.customer_id = auth.uid() then
      v_cancel_statuses := public.ops_policy_value('cancellation_allowed_statuses');
    elsif v_role = 'seller' and v_is_store_owner then
      v_cancel_statuses := public.ops_policy_value('cancellation_allowed_statuses_seller');
    else
      raise exception using errcode = 'P0001', message = 'status_transition_not_allowed';
    end if;
    if v_role <> 'admin' then
      -- An empty/missing list for this actor means the policy is not configured
      -- for them (same fail-closed meaning as before).
      if nullif(btrim(coalesce(v_cancel_statuses, '')), '') is null then
        raise exception using errcode = 'P0001', message = 'cancellation_policy_not_configured';
      end if;
      if not (v_order.order_status::text = any (string_to_array(v_cancel_statuses, ','))) then
        raise exception using errcode = 'P0001', message = 'status_transition_not_allowed';
      end if;
    end if;
    if nullif(btrim(p_note), '') is null then
      raise exception using errcode = 'P0001', message = 'cancellation_reason_required';
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

  -- Completion actor is a business decision that is not approved yet: no default and no fallback.
  -- Missing/invalid policy rejects `completed` for EVERY role, admin included, before any role check.
  -- Operators configure it explicitly with provision_set_policy('completion_actor', ...).
  if p_new_status = 'completed' then
    v_completion_actor := public.ops_policy_value('completion_actor');
    if v_completion_actor is null or v_completion_actor not in ('customer', 'seller', 'driver') then
      raise exception using errcode = 'P0001', message = 'completion_policy_not_configured';
    end if;
  end if;

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
  -- Completion actor is operator-configured (no default; checked above).
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
-- 3. Seed kebijakan pembatalan (keputusan pemilik 12 Nov 2026)
-- ---------------------------------------------------------------------------

insert into public.ops_policy (key, value) values
  ('cancellation_enabled', 'true'),
  ('cancellation_allowed_statuses', 'pending_seller'),
  ('cancellation_allowed_statuses_seller', 'pending_seller,accepted,preparing')
on conflict (key) do update set value = excluded.value, updated_at = now();

comment on table public.ops_policy is 'Operational policy flags. Writable only through provision_set_policy (service_role/postgres). Cancellation is enabled per owner decision 2026-11-12 (customer: pending_seller; seller: pending_seller,accepted,preparing; admin: any status); other decisions stay fail-closed.';

commit;
