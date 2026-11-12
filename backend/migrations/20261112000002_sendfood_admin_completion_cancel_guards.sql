-- SendFood: guard admin untuk completed + larang batal dari status terminal
-- (keputusan pemilik 12 Nov 2026, rencana backend-loophole-fix-plan.md)
-- Applies on top of 20261112000000_sendfood_cancel_per_actor.sql (do not edit that file).
--
-- Dua celah yang ditutup di change_order_status (bagian lain fungsi tidak berubah):
-- * Batal dari status terminal: sebelumnya admin melewati daftar status sepenuhnya,
--   sehingga pesanan yang sudah `completed` (juga `cancelled`/`rejected`) masih bisa
--   dibatalkan. Sekarang batal ditolak bila status saat ini adalah `completed`,
--   `cancelled`, atau `rejected` — berlaku untuk SEMUA aktor termasuk admin.
--   Admin tetap bypass daftar status untuk status non-terminal.
--   Error baru: cancel_from_terminal_status_not_allowed.
-- * Admin override "selesai" tanpa alasan: sebelumnya jalur `completed` hanya
--   memeriksa kebijakan `completion_actor`, tanpa mewajibkan catatan. Sekarang
--   bila role = admin dan p_new_status = 'completed', p_note wajib tidak kosong.
--   Error baru: completion_reason_required (sejajar cancellation_reason_required).
--   Driver/pelanggan/penjual yang menyelesaikan sesuai `completion_actor` tetap
--   TANPA alasan wajib, supaya antar harian tidak terhambat.
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
    raise exception using errcode = 'P0001', message = 'admin_guards_require_cancel_per_actor_migration';
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- 1. change_order_status: guard batal-terminal + alasan wajib override admin
--    (bagian lain fungsi tidak berubah dari migrasi 20261112000000)
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
    -- Status terminal tidak bisa dibatalkan lagi (semua aktor, termasuk admin).
    if v_order.order_status in ('completed', 'cancelled', 'rejected') then
      raise exception using errcode = 'P0001', message = 'cancel_from_terminal_status_not_allowed';
    end if;
    -- Per-actor status lists. Admin bypasses the list entirely (any non-terminal status).
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
    -- Admin override wajib beralasan; aktor completion biasa (driver/pelanggan/penjual)
    -- yang menyelesaikan sesuai kebijakan tetap tanpa alasan wajib.
    if v_role = 'admin' and nullif(btrim(p_note), '') is null then
      raise exception using errcode = 'P0001', message = 'completion_reason_required';
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

comment on function public.change_order_status(uuid, public.order_status, text) is 'Status transitions with per-actor cancel rules (20261112000000) + terminal-cancel guard and admin-completion-reason guard (20261112000002).';

-- ---------------------------------------------------------------------------
-- 2. Perbarui komentar kebijakan: admin tidak lagi "status mana pun"
-- ---------------------------------------------------------------------------

comment on table public.ops_policy is 'Operational policy flags. Writable only through provision_set_policy (service_role/postgres). Cancellation is enabled per owner decision 2026-11-12 (customer: pending_seller; seller: pending_seller,accepted,preparing; admin: any non-terminal status); terminal orders (completed/cancelled/rejected) cannot be cancelled by anyone (20261112000002); admin completion override requires a reason; other decisions stay fail-closed.';

commit;
