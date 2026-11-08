-- Regresi nilai non-finite (NaN) pada konfigurasi pengiriman toko dan jumlah uang order.
-- Kolom foundation stores.delivery_fee numeric(12,2) / service_radius_km numeric(8,2) hanya punya
-- check >= 0, dan di PostgreSQL 'NaN'::numeric >= 0 bernilai true, NaN = NaN true, dan x > NaN false.
-- Tanpa guard: fee NaN -> total NaN tersimpan; radius NaN -> pembanding jarak selalu false (radius terlewati).
-- Infinity tidak bisa disimpan di numeric bertipe-mod (numeric field overflow), jadi cukup NaN.
-- Hanya aman di database sementara sendfood_test_*. Constraint di-drop HANYA di dalam transaksi lalu ROLLBACK.
\set ON_ERROR_STOP on
DO $$
BEGIN
  IF current_database() !~ '^sendfood_test_' THEN
    RAISE EXCEPTION 'nonfinite_test_refused_not_a_test_database';
  END IF;
END
$$;

-- A. Constraint skema menolak NaN baru (juga untuk superuser/migrasi), bukan hanya RPC admin.
DO $$
BEGIN
  PERFORM t.ok('nonfinite: constraint stores_delivery_fee_not_nan ada dan tervalidasi',
    EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.stores'::regclass AND conname='stores_delivery_fee_not_nan' AND convalidated));
  PERFORM t.ok('nonfinite: constraint stores_service_radius_not_nan ada dan tervalidasi',
    EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.stores'::regclass AND conname='stores_service_radius_not_nan' AND convalidated));
  PERFORM t.ok('nonfinite: constraint orders_amounts_not_nan ada dan tervalidasi',
    EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.orders'::regclass AND conname='orders_amounts_not_nan' AND convalidated));
  PERFORM t.ok('nonfinite: constraint order_items_amounts_not_nan ada dan tervalidasi',
    EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.order_items'::regclass AND conname='order_items_amounts_not_nan' AND convalidated));
  PERFORM t.expect_err('nonfinite: UPDATE stores.delivery_fee = NaN ditolak constraint',
    $q$update public.stores set delivery_fee = 'NaN' where id = '50000000-0000-0000-0000-00000000000a'$q$, 'stores_delivery_fee_not_nan');
  PERFORM t.expect_err('nonfinite: UPDATE stores.service_radius_km = NaN ditolak constraint',
    $q$update public.stores set service_radius_km = 'NaN' where id = '50000000-0000-0000-0000-00000000000a'$q$, 'stores_service_radius_not_nan');
END
$$;

-- B. Defense in depth create_order: baris legacy/bypass dengan fee NaN.
BEGIN;
DO $$
DECLARE o1 bigint; i1 bigint; h1 bigint;
BEGIN
  ALTER TABLE public.stores DROP CONSTRAINT IF EXISTS stores_delivery_fee_not_nan;
  ALTER TABLE public.orders DROP CONSTRAINT IF EXISTS orders_amounts_not_nan;
  ALTER TABLE public.order_items DROP CONSTRAINT IF EXISTS order_items_amounts_not_nan;
  UPDATE public.stores SET delivery_fee = 'NaN' WHERE id = '50000000-0000-0000-0000-00000000000a';
  SELECT count(*) INTO o1 FROM public.orders; SELECT count(*) INTO i1 FROM public.order_items;
  SELECT count(*) INTO h1 FROM public.order_status_history;
  PERFORM t.login('10000000-0000-0000-0000-00000000000a');
  PERFORM t.expect_err('nonfinite: checkout pada toko dengan delivery_fee NaN ditolak (store_delivery_not_configured)',
    t.co_sql('50000000-0000-0000-0000-00000000000a', '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":1}]'::jsonb,
      '-6.21', '106.81', 'cod', 'nonfinite-fee-01'), 'store_delivery_not_configured');
  PERFORM t.logout();
  PERFORM t.ok('nonfinite: tidak ada order dengan total NaN',
    NOT EXISTS (SELECT 1 FROM public.orders WHERE total = 'NaN' OR delivery_fee = 'NaN' OR subtotal = 'NaN'));
  PERFORM t.ok('nonfinite: fee NaN -> jumlah orders/order_items/history tidak berubah',
    (SELECT count(*) FROM public.orders) = o1 AND (SELECT count(*) FROM public.order_items) = i1
    AND (SELECT count(*) FROM public.order_status_history) = h1);
END
$$;
ROLLBACK;

-- C. Defense in depth create_order: radius NaN tidak boleh meloloskan alamat jauh (bypass radius).
BEGIN;
DO $$
DECLARE o1 bigint;
BEGIN
  ALTER TABLE public.stores DROP CONSTRAINT IF EXISTS stores_service_radius_not_nan;
  UPDATE public.stores SET service_radius_km = 'NaN' WHERE id = '50000000-0000-0000-0000-00000000000a';
  SELECT count(*) INTO o1 FROM public.orders;
  PERFORM t.login('10000000-0000-0000-0000-00000000000a');
  -- Sekitar 60 km dari toko A: jelas di luar radius 5 km yang sah.
  PERFORM t.expect_err('nonfinite: radius NaN + alamat jauh ditolak, tidak melewati radius',
    t.co_sql('50000000-0000-0000-0000-00000000000a', '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":1}]'::jsonb,
      '-6.5', '107.2', 'cod', 'nonfinite-radius-01'), 'store_delivery_not_configured');
  PERFORM t.expect_err('nonfinite: radius NaN + alamat dekat juga ditolak (konfigurasi tidak valid)',
    t.co_sql('50000000-0000-0000-0000-00000000000a', '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":1}]'::jsonb,
      '-6.21', '106.81', 'cod', 'nonfinite-radius-02'), 'store_delivery_not_configured');
  PERFORM t.logout();
  PERFORM t.ok('nonfinite: radius NaN -> tidak ada order baru', (SELECT count(*) FROM public.orders) = o1);
END
$$;
ROLLBACK;

-- D. Katalog tidak menandai toko dengan radius NaN sebagai dalam radius.
BEGIN;
DO $$
BEGIN
  ALTER TABLE public.stores DROP CONSTRAINT IF EXISTS stores_service_radius_not_nan;
  UPDATE public.stores SET service_radius_km = 'NaN' WHERE id = '50000000-0000-0000-0000-00000000000a';
  PERFORM t.ok('nonfinite: list_stores tidak mengklaim within_service_radius=true untuk radius NaN',
    (SELECT within_service_radius IS DISTINCT FROM true FROM public.list_stores(null, -6.5, 107.2, 'nearest', 50, 0)
      WHERE id = '50000000-0000-0000-0000-00000000000a'));
END
$$;
ROLLBACK;

-- E. Setelah ROLLBACK: konfigurasi dan constraint pulih; checkout sah tetap jalan.
DO $$
BEGIN
  PERFORM t.ok('nonfinite: konfigurasi toko A pulih (fee 5000, radius 5)',
    (SELECT delivery_fee = 5000 AND service_radius_km = 5 FROM public.stores WHERE id = '50000000-0000-0000-0000-00000000000a'));
  PERFORM t.ok('nonfinite: constraint stores pulih setelah rollback',
    (SELECT count(*) FROM pg_constraint WHERE conrelid='public.stores'::regclass
      AND conname IN ('stores_delivery_fee_not_nan','stores_service_radius_not_nan')) = 2);
END
$$;
