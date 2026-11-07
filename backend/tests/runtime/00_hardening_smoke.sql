-- Smoke test migrasi hardening (tes lengkap ada di FEAT-003).
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'cust@example.test'),
  ('00000000-0000-0000-0000-0000000000a2', 'sell@example.test');
select public.provision_set_user_role('00000000-0000-0000-0000-0000000000a2', 'seller', 'smoke');

insert into public.stores (id, owner_id, name, address, latitude, longitude, is_active, delivery_fee, service_radius_km)
values ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a2',
        'Warung Uji', 'Jl. Uji 1', -6.200000, 106.800000, true, 5000, 5);
insert into public.products (id, store_id, name, price)
values ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b1', 'Nasi', 10000);

do $$
declare v_id uuid; v_id2 uuid; v_msg text; v_cnt int;
begin
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
  set local role authenticated;

  -- role escalation must fail
  begin
    update public.profiles set role = 'admin' where id = auth.uid();
    raise exception 'escalation_not_blocked';
  exception when insufficient_privilege then null;
  end;

  -- idempotent create_order
  select o.order_id into v_id from public.create_order(
    '00000000-0000-0000-0000-0000000000b1',
    '[{"product_id":"00000000-0000-0000-0000-0000000000c1","quantity":2}]'::jsonb,
    'Jl. Tujuan 2', -6.2010, 106.8010, null, 'cod', 'idem-key-0001') o;
  select o.order_id into v_id2 from public.create_order(
    '00000000-0000-0000-0000-0000000000b1',
    '[{"product_id":"00000000-0000-0000-0000-0000000000c1","quantity":2}]'::jsonb,
    'Jl. Tujuan 2', -6.2010, 106.8010, null, 'cod', 'idem-key-0001') o;
  if v_id is distinct from v_id2 then raise exception 'idempotency_failed'; end if;

  -- direct order write blocked
  begin
    delete from public.orders;
    raise exception 'direct_write_not_blocked';
  exception when insufficient_privilege or sqlstate 'P0001' then null;
  end;

  -- cancellation fails closed
  begin
    perform public.change_order_status(v_id, 'cancelled', 'x');
    raise exception 'cancel_not_blocked';
  exception when sqlstate 'P0001' then
    get stacked diagnostics v_msg = message_text;
    if v_msg <> 'cancellation_policy_not_configured' then raise exception 'wrong_error %', v_msg; end if;
  end;

  -- search with sort
  select count(*) into v_cnt from public.search_products('nasi', null, null, null, -6.2, 106.8, 'cheapest');
  if v_cnt <> 1 then raise exception 'search_failed'; end if;

  -- client cannot call provisioning
  begin
    perform public.provision_set_user_role(auth.uid(), 'admin');
    raise exception 'provision_not_blocked';
  exception when insufficient_privilege then null;
  end;

  reset role;
  raise notice 'PASS: hardening smoke';
end
$$;

rollback;
