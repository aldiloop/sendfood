-- Regresi harga NaN: constraint products_price_not_nan (insert/update jalur seller yang diotorisasi)
-- dan defense-in-depth create_order untuk baris legacy/bypass.
-- Hanya aman di database sementara sendfood_test_*. Constraint di-drop HANYA di dalam transaksi
-- lokal lalu di-ROLLBACK; pemulihan diperiksa setelah ROLLBACK.
\set ON_ERROR_STOP on
DO $$
BEGIN
  IF current_database() !~ '^sendfood_test_' THEN
    RAISE EXCEPTION 'price_nan_test_refused_not_a_test_database';
  END IF;
END
$$;

BEGIN;

-- A. Seller A (pemilik toko A) menyisipkan/mengubah harga: NaN ditolak oleh constraint, bukan RLS/permission.
DO $$
DECLARE
  v_cnt_before bigint; v_cnt_after bigint; v_price_before numeric; v_state text; v_con text;
BEGIN
  PERFORM t.login('20000000-0000-0000-0000-00000000000a');
  -- Kontrol jalur otorisasi: insert dan update harga valid oleh seller yang sama berhasil.
  INSERT INTO public.products (store_id, name, price)
    VALUES ('50000000-0000-0000-0000-00000000000a', 'kontrol harga valid', 1000);
  PERFORM t.ok('nan: seller A insert produk harga valid berhasil (jalur otorisasi sah)',
    EXISTS (SELECT 1 FROM public.products WHERE name = 'kontrol harga valid'));

  SELECT count(*) INTO v_cnt_before FROM public.products WHERE store_id = '50000000-0000-0000-0000-00000000000a';
  SELECT price INTO v_price_before FROM public.products WHERE id = '60000000-0000-0000-0000-0000000000a1';

  PERFORM t.expect_err('nan: seller A insert produk harga NaN ditolak constraint',
    $q$insert into public.products (store_id, name, price) values ('50000000-0000-0000-0000-00000000000a', 'produk nan', 'NaN'::numeric)$q$,
    'products_price_not_nan');
  PERFORM t.expect_err('nan: seller A update harga NaN ditolak constraint',
    $q$update public.products set price = 'NaN'::numeric where id = '60000000-0000-0000-0000-0000000000a1'$q$,
    'products_price_not_nan');

  -- SQLSTATE dan nama constraint (insert).
  BEGIN
    INSERT INTO public.products (store_id, name, price)
      VALUES ('50000000-0000-0000-0000-00000000000a', 'produk nan 2', 'NaN'::numeric);
    PERFORM t.ok('nan: insert NaN seharusnya error', false);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_con = CONSTRAINT_NAME;
    v_state := SQLSTATE;
    PERFORM t.ok('nan: insert NaN -> SQLSTATE 23514 constraint products_price_not_nan',
      v_state = '23514' AND v_con = 'products_price_not_nan');
  END;
  -- SQLSTATE dan nama constraint (update).
  BEGIN
    UPDATE public.products SET price = 'NaN'::numeric WHERE id = '60000000-0000-0000-0000-0000000000a1';
    PERFORM t.ok('nan: update NaN seharusnya error', false);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_con = CONSTRAINT_NAME;
    v_state := SQLSTATE;
    PERFORM t.ok('nan: update NaN -> SQLSTATE 23514 constraint products_price_not_nan',
      v_state = '23514' AND v_con = 'products_price_not_nan');
  END;

  SELECT count(*) INTO v_cnt_after FROM public.products WHERE store_id = '50000000-0000-0000-0000-00000000000a';
  PERFORM t.ok('nan: jumlah produk toko A tidak berubah setelah insert NaN ditolak', v_cnt_before = v_cnt_after);
  PERFORM t.ok('nan: harga produk a1 tidak berubah setelah update NaN ditolak',
    (SELECT price FROM public.products WHERE id = '60000000-0000-0000-0000-0000000000a1') = v_price_before
    AND v_price_before <> 'NaN'::numeric);
  PERFORM t.ok('nan: tidak ada baris NaN di tabel setelah penolakan',
    NOT EXISTS (SELECT 1 FROM public.products WHERE price = 'NaN'::numeric));
  PERFORM t.logout();
END
$$;
ROLLBACK;

-- B. Checkout terhadap baris legacy NaN (constraint di-bypass transaction-local).
BEGIN;
DO $$
DECLARE
  o1 bigint; i1 bigint; h1 bigint; o2 bigint; i2 bigint; h2 bigint;
BEGIN
  PERFORM t.logout();
  ALTER TABLE public.products DROP CONSTRAINT products_price_not_nan;
  UPDATE public.products SET price = 'NaN'::numeric WHERE id = '60000000-0000-0000-0000-0000000000a1';
  PERFORM t.ok('nan: fixture legacy NaN terpasang (constraint di-bypass dalam transaksi)',
    (SELECT price FROM public.products WHERE id = '60000000-0000-0000-0000-0000000000a1') = 'NaN'::numeric);

  SELECT count(*) INTO o1 FROM public.orders;
  SELECT count(*) INTO i1 FROM public.order_items;
  SELECT count(*) INTO h1 FROM public.order_status_history;

  PERFORM t.login('10000000-0000-0000-0000-00000000000a');
  PERFORM t.expect_err('nan: checkout produk NaN ditolak invalid_product_price',
    t.co_sql('50000000-0000-0000-0000-00000000000a',
      '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":1}]'::jsonb,
      '-6.21', '106.81', 'cod', 'nan-price-check-01'),
    'invalid_product_price');
  PERFORM t.expect_err('nan: checkout campuran (NaN + valid) ditolak invalid_product_price',
    t.co_sql('50000000-0000-0000-0000-00000000000a',
      '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":1},{"product_id":"60000000-0000-0000-0000-0000000000a2","quantity":2}]'::jsonb,
      '-6.21', '106.81', 'cod', 'nan-price-check-02'),
    'invalid_product_price');
  PERFORM t.logout();

  SELECT count(*) INTO o2 FROM public.orders;
  SELECT count(*) INTO i2 FROM public.order_items;
  SELECT count(*) INTO h2 FROM public.order_status_history;
  PERFORM t.ok('nan: jumlah orders sebelum/sesudah identik', o1 = o2);
  PERFORM t.ok('nan: jumlah order_items sebelum/sesudah identik (tanpa orphan)', i1 = i2);
  PERFORM t.ok('nan: jumlah order_status_history sebelum/sesudah identik (tanpa orphan)', h1 = h2);
  PERFORM t.ok('nan: tidak ada orders dengan idempotency key uji',
    NOT EXISTS (SELECT 1 FROM public.orders WHERE idempotency_key IN ('nan-price-check-01','nan-price-check-02')));

  -- Kontrol: produk valid pada toko yang sama tetap bisa di-checkout (penolakan spesifik NaN).
  PERFORM t.login('10000000-0000-0000-0000-00000000000a');
  EXECUTE t.co_sql('50000000-0000-0000-0000-00000000000a',
    '[{"product_id":"60000000-0000-0000-0000-0000000000a2","quantity":1}]'::jsonb,
    '-6.21', '106.81', 'cod', 'nan-price-check-03');
  PERFORM t.logout();
  PERFORM t.ok('nan: checkout produk valid tetap berhasil',
    (SELECT count(*) FROM public.orders) = o1 + 1);
END
$$;
ROLLBACK;

-- C. Setelah ROLLBACK: constraint pulih dan tidak ada sisa fixture NaN.
DO $$
BEGIN
  PERFORM t.ok('nan: constraint products_price_not_nan pulih setelah rollback',
    EXISTS (SELECT 1 FROM pg_catalog.pg_constraint c
            WHERE c.conrelid = 'public.products'::regclass
              AND c.conname = 'products_price_not_nan' AND c.contype = 'c' AND c.convalidated
              AND pg_get_constraintdef(c.oid) = 'CHECK ((price <> ''NaN''::numeric))'));
  PERFORM t.ok('nan: tidak ada harga NaN tersisa setelah rollback',
    NOT EXISTS (SELECT 1 FROM public.products WHERE price = 'NaN'::numeric));
  PERFORM t.ok('nan: harga produk a1 pulih ke 10000',
    (SELECT price FROM public.products WHERE id = '60000000-0000-0000-0000-0000000000a1') = 10000);
  PERFORM t.ok('nan: tidak ada order/item/riwayat uji tersisa setelah rollback',
    NOT EXISTS (SELECT 1 FROM public.orders WHERE idempotency_key LIKE 'nan-price-check-%'));
END
$$;
