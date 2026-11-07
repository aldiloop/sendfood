-- Read-only structural verification for the SendFood foundation migration.
-- Run through Supabase SQL after migration; every SELECT includes a LIMIT.
select check_name, passed
from (
  values
    (
      'six public application tables exist',
      (select count(*) = 6
       from (select tablename from pg_catalog.pg_tables
             where schemaname = 'public'
               and tablename in ('profiles','stores','products','orders','order_items','order_status_history')
             limit 6) as found_tables)
    ),
    (
      'RLS enabled on all six application tables',
      (select count(*) = 6
       from (select c.relname from pg_catalog.pg_class c
             where c.relnamespace = 'public'::regnamespace
               and c.relname in ('profiles','stores','products','orders','order_items','order_status_history')
               and c.relrowsecurity = true
             limit 6) as protected_tables)
    ),
    (
      'three public RPCs exist',
      (select count(*) = 3
       from (select p.proname from pg_catalog.pg_proc p
             where p.pronamespace = 'public'::regnamespace
               and p.proname in ('create_order','change_order_status','assign_order_driver')
             limit 3) as public_rpcs)
    ),
    (
      'order snapshot and status-history indexes exist',
      (select count(*) = 2
       from (select i.indexrelid
             from pg_catalog.pg_index i
             join pg_catalog.pg_class t on t.oid = i.indrelid
             join pg_catalog.pg_class ix on ix.oid = i.indexrelid
             where t.relnamespace = 'public'::regnamespace
               and ix.relname in ('order_items_order_id_idx','order_status_history_order_created_idx')
             limit 2) as expected_indexes)
    ),
    (
      'product price excludes numeric NaN',
      (select exists (
       select 1
       from pg_catalog.pg_constraint c
       where c.conrelid = 'public.products'::regclass
         and c.conname = 'products_price_not_nan'
         and c.contype = 'c'
         and c.convalidated
       limit 1))
    )
) as checks(check_name, passed)
order by check_name
limit 100;
