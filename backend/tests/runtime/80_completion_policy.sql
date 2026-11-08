-- Kebijakan aktor completion fail-closed: tanpa baris / nilai tidak valid -> `completed` ditolak
-- completion_policy_not_configured untuk SEMUA peran, termasuk admin, tanpa mengubah order/history.
-- Konfigurasi eksplisit (fixture sintetis, bukan keputusan bisnis) -> hanya aktor itu (dan admin, sesuai kontrak).
-- Hanya di database sendfood_test_*. Perubahan ops_policy dilakukan di dalam transaksi lalu ROLLBACK.
\set ON_ERROR_STOP on
DO $$
BEGIN
  IF current_database() !~ '^sendfood_test_' THEN
    RAISE EXCEPTION 'completion_test_refused_not_a_test_database';
  END IF;
END
$$;

-- Order sampai delivered (dibuat dalam transaksi tiap skenario).
CREATE OR REPLACE FUNCTION t.delivered_order(p_key text) RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE o uuid;
BEGIN
  o := t.make_order('10000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-00000000000a',
                    '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":1}]'::jsonb, p_key);
  PERFORM t.status_as('20000000-0000-0000-0000-00000000000a', o, 'accepted');
  PERFORM t.login('40000000-0000-0000-0000-000000000001');
  PERFORM public.assign_order_driver(o, '30000000-0000-0000-0000-00000000000a');
  PERFORM t.logout();
  PERFORM t.status_as('20000000-0000-0000-0000-00000000000a', o, 'preparing');
  PERFORM t.status_as('20000000-0000-0000-0000-00000000000a', o, 'ready_for_pickup');
  PERFORM t.status_as('30000000-0000-0000-0000-00000000000a', o, 'picked_up');
  PERFORM t.status_as('30000000-0000-0000-0000-00000000000a', o, 'delivered');
  RETURN o;
END $f$;

-- Semua peran terkait (customer pemilik, seller pemilik, driver ditugaskan, admin) harus ditolak dengan p_expected.
CREATE OR REPLACE FUNCTION t.all_roles_rejected(p_label text, o uuid, p_expected text) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE r record; h bigint; v text := format('select public.change_order_status(%L, ''completed'', null)', o);
BEGIN
  SELECT count(*) INTO h FROM public.order_status_history WHERE order_id = o;
  FOR r IN SELECT * FROM (VALUES ('customer', '10000000-0000-0000-0000-00000000000a'::uuid),
      ('seller', '20000000-0000-0000-0000-00000000000a'::uuid), ('driver', '30000000-0000-0000-0000-00000000000a'::uuid),
      ('admin', '40000000-0000-0000-0000-000000000001'::uuid)) AS x(role, uid) LOOP
    PERFORM t.login(r.uid);
    PERFORM t.expect_err(format('completion %s: %s ditolak', p_label, r.role), v, p_expected);
    PERFORM t.logout();
  END LOOP;
  PERFORM t.ok(format('completion %s: order tetap delivered, payment unpaid', p_label),
    (SELECT order_status = 'delivered' AND payment_status = 'unpaid' FROM public.orders WHERE id = o));
  PERFORM t.ok(format('completion %s: history tidak bertambah', p_label),
    (SELECT count(*) FROM public.order_status_history WHERE order_id = o) = h);
END $f$;

-- A. Tanpa baris completion_actor (keadaan migrasi bersih).
BEGIN;
DELETE FROM public.ops_policy WHERE key = 'completion_actor';
SELECT t.all_roles_rejected('tanpa kebijakan', t.delivered_order('completion-none-01'), 'completion_policy_not_configured');
ROLLBACK;

-- B. Nilai tidak valid yang tertulis langsung oleh superuser (melewati validasi provision_set_policy).
BEGIN;
UPDATE public.ops_policy SET value = 'admin' WHERE key = 'completion_actor';
SELECT t.all_roles_rejected('nilai admin', t.delivered_order('completion-bad-01'), 'completion_policy_not_configured');
UPDATE public.ops_policy SET value = '' WHERE key = 'completion_actor';
SELECT t.all_roles_rejected('nilai kosong', t.delivered_order('completion-bad-02'), 'completion_policy_not_configured');
UPDATE public.ops_policy SET value = 'Customer' WHERE key = 'completion_actor';
SELECT t.all_roles_rejected('nilai huruf besar', t.delivered_order('completion-bad-03'), 'completion_policy_not_configured');
ROLLBACK;

-- C. Kebijakan tidak mengubah validitas transisi: completed dari selain delivered tetap status_transition_not_allowed.
BEGIN;
DELETE FROM public.ops_policy WHERE key = 'completion_actor';
DO $$
DECLARE o uuid;
BEGIN
  o := t.make_order('10000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-00000000000a',
                    '[{"product_id":"60000000-0000-0000-0000-0000000000a1","quantity":1}]'::jsonb, 'completion-skip-01');
  PERFORM t.login('40000000-0000-0000-0000-000000000001');
  PERFORM t.expect_err('completion tanpa kebijakan: admin pending_seller -> completed tetap transisi tidak sah',
    format('select public.change_order_status(%L, ''completed'', null)', o), 'status_transition_not_allowed');
  PERFORM t.logout();
END $$;
ROLLBACK;

-- D. Konfigurasi eksplisit driver (fixture sintetis): driver ditugaskan boleh; customer/seller/driver lain ditolak.
BEGIN;
SELECT public.provision_set_policy('completion_actor', 'driver');
DO $$
DECLARE o uuid := t.delivered_order('completion-driver-01');
  v text;
BEGIN
  v := format('select public.change_order_status(%L, ''completed'', null)', o);
  PERFORM t.login('10000000-0000-0000-0000-00000000000a');
  PERFORM t.expect_err('completion=driver: customer ditolak', v, 'status_transition_not_allowed');
  PERFORM t.login('20000000-0000-0000-0000-00000000000a');
  PERFORM t.expect_err('completion=driver: seller ditolak', v, 'status_transition_not_allowed');
  PERFORM t.login('30000000-0000-0000-0000-00000000000b');
  PERFORM t.expect_err('completion=driver: driver lain ditolak', v, 'status_transition_not_allowed');
  PERFORM t.logout();
  PERFORM t.status_as('30000000-0000-0000-0000-00000000000a', o, 'completed');
  PERFORM t.ok('completion=driver: driver ditugaskan berhasil, payment tetap unpaid',
    (SELECT order_status = 'completed' AND payment_status = 'unpaid' FROM public.orders WHERE id = o));
  PERFORM t.ok('completion=driver: history mencatat driver sebagai aktor',
    EXISTS (SELECT 1 FROM public.order_status_history WHERE order_id = o AND new_status = 'completed'
            AND changed_by = '30000000-0000-0000-0000-00000000000a'));
END $$;
ROLLBACK;

-- E. Admin setelah kebijakan dikonfigurasi: boleh (kontrak: admin dapat melakukan transisi sah), tercatat sebagai aktor.
BEGIN;
SELECT public.provision_set_policy('completion_actor', 'customer');
DO $$
DECLARE o uuid := t.delivered_order('completion-admin-01');
BEGIN
  PERFORM t.status_as('40000000-0000-0000-0000-000000000001', o, 'completed');
  PERFORM t.ok('completion dikonfigurasi: admin boleh menyelesaikan (override kontrak), tercatat',
    EXISTS (SELECT 1 FROM public.order_status_history WHERE order_id = o AND new_status = 'completed'
            AND changed_by = '40000000-0000-0000-0000-000000000001'));
END $$;
ROLLBACK;

-- F. Hanya service_role/postgres yang bisa menyetel kebijakan; authenticated ditolak.
DO $$
BEGIN
  PERFORM t.login('40000000-0000-0000-0000-000000000001');
  PERFORM t.expect_err('completion: admin aplikasi tidak bisa provision_set_policy',
    $q$select public.provision_set_policy('completion_actor', 'seller')$q$, 'permission denied');
  PERFORM t.logout();
  PERFORM t.ok('completion: fixture kebijakan tetap customer setelah semua rollback',
    (SELECT value FROM public.ops_policy WHERE key = 'completion_actor') = 'customer');
END $$;

DROP FUNCTION t.all_roles_rejected(text, uuid, text);
DROP FUNCTION t.delivered_order(text);
