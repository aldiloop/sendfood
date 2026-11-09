-- SendFood: RLS initplan + foreign-key index performance fix (forward migration, v3)
-- Applies on top of 20261108000000_sendfood_backend_mvp_hardening.sql. Does not edit earlier files.
--
-- Why:
-- * Supabase performance advisor `auth_rls_initplan`: policies that call auth.uid() (and the
--   STABLE SECURITY DEFINER public.current_app_role()) directly are re-evaluated per row.
--   Wrapping them in a scalar subquery `(select ...)` lets Postgres evaluate them once per query
--   (InitPlan). The predicate logic is unchanged.
-- * Supabase performance advisor `unindexed_foreign_keys`: add covering indexes for FKs.
--
-- Safety:
-- * ALTER POLICY only replaces USING / WITH CHECK expressions. Policy names, commands, roles,
--   permissive mode and table grants stay exactly as they are.
-- * One explicit transaction with lock_timeout: fails fast and rolls back entirely on error.
--   Always apply with `psql -X -v ON_ERROR_STOP=1` or paste the whole file in the SQL editor.

begin;
set local lock_timeout = '5s';
set local statement_timeout = '120s';

do $$
begin
  if to_regclass('public.ops_policy') is null or to_regclass('public.customer_addresses') is null then
    raise exception using errcode = 'P0001', message = 'perf_fix_requires_hardening_migration';
  end if;
end
$$;

-- profiles
alter policy profiles_select_self_or_admin on public.profiles
  using (id = (select auth.uid()) or (select public.current_app_role()) = 'admin');
alter policy profiles_update_self on public.profiles
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- stores
alter policy stores_authenticated_read on public.stores
  using (is_active = true or owner_id = (select auth.uid())
         or (select public.current_app_role()) = 'admin');
alter policy stores_seller_insert_own on public.stores
  with check (owner_id = (select auth.uid()) and (select public.current_app_role()) = 'seller');
alter policy stores_seller_update_own on public.stores
  using (owner_id = (select auth.uid()) and (select public.current_app_role()) = 'seller')
  with check (owner_id = (select auth.uid()) and (select public.current_app_role()) = 'seller');

-- products
alter policy products_authenticated_read on public.products
  using (
    (is_available = true and exists (
      select 1 from public.stores s where s.id = products.store_id and s.is_active = true))
    or exists (
      select 1 from public.stores s where s.id = products.store_id and s.owner_id = (select auth.uid()))
    or (select public.current_app_role()) = 'admin'
  );
alter policy products_seller_insert_own on public.products
  with check (
    (select public.current_app_role()) = 'seller'
    and exists (select 1 from public.stores s
                where s.id = products.store_id and s.owner_id = (select auth.uid()))
  );
alter policy products_seller_update_own on public.products
  using (
    (select public.current_app_role()) = 'seller'
    and exists (select 1 from public.stores s
                where s.id = products.store_id and s.owner_id = (select auth.uid()))
  )
  with check (
    (select public.current_app_role()) = 'seller'
    and exists (select 1 from public.stores s
                where s.id = products.store_id and s.owner_id = (select auth.uid()))
  );
alter policy products_seller_delete_own on public.products
  using (
    (select public.current_app_role()) = 'seller'
    and exists (select 1 from public.stores s
                where s.id = products.store_id and s.owner_id = (select auth.uid()))
  );

-- orders, order_items, order_status_history
alter policy orders_participant_read on public.orders
  using (
    customer_id = (select auth.uid())
    or driver_id = (select auth.uid())
    or (select public.current_app_role()) = 'admin'
    or exists (select 1 from public.stores s
               where s.id = orders.store_id and s.owner_id = (select auth.uid()))
  );
alter policy order_items_participant_read on public.order_items
  using (exists (
    select 1 from public.orders o
    where o.id = order_items.order_id
      and (o.customer_id = (select auth.uid())
           or o.driver_id = (select auth.uid())
           or (select public.current_app_role()) = 'admin'
           or exists (select 1 from public.stores s
                      where s.id = o.store_id and s.owner_id = (select auth.uid())))
  ));
alter policy order_status_history_participant_read on public.order_status_history
  using (exists (
    select 1 from public.orders o
    where o.id = order_status_history.order_id
      and (o.customer_id = (select auth.uid())
           or o.driver_id = (select auth.uid())
           or (select public.current_app_role()) = 'admin'
           or exists (select 1 from public.stores s
                      where s.id = o.store_id and s.owner_id = (select auth.uid())))
  ));

-- customer_addresses
alter policy customer_addresses_select_own on public.customer_addresses
  using (customer_id = (select auth.uid()));
alter policy customer_addresses_insert_own on public.customer_addresses
  with check (customer_id = (select auth.uid()) and (select public.current_app_role()) = 'customer');
alter policy customer_addresses_update_own on public.customer_addresses
  using (customer_id = (select auth.uid()))
  with check (customer_id = (select auth.uid()) and (select public.current_app_role()) = 'customer');
alter policy customer_addresses_delete_own on public.customer_addresses
  using (customer_id = (select auth.uid()));

-- admin_audit_log
alter policy admin_audit_log_admin_read on public.admin_audit_log
  using ((select public.current_app_role()) = 'admin');

-- Covering indexes for foreign keys flagged by the advisor (tables are small at MVP stage).
create index if not exists order_items_product_id_idx on public.order_items(product_id);
create index if not exists order_status_history_changed_by_idx on public.order_status_history(changed_by);
create index if not exists admin_audit_log_actor_id_idx on public.admin_audit_log(actor_id);

commit;
