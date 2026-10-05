-- Agro POS — Phase 3 RLS isolation test. READ-ONLY IN EFFECT: it adds a few rows named 'ZZ_TEST ...',
-- checks what each shop can and cannot do, then deletes them again. Run it in the Supabase SQL Editor.
--
-- BEFORE RUNNING: replace the two emails below with the logins of two DIFFERENT shops
-- (your Shop A and Shop B test accounts). Then press Run. You get one table of PASS/FAIL rows.
-- Everything happens in one transaction: if anything unexpected throws, it is rolled back as a whole.

create or replace function pg_temp.try(q text) returns text language plpgsql as $$
declare n bigint;
begin
  execute q; get diagnostics n = row_count; return 'OK rows=' || n;
exception when others then return 'ERR ' || sqlstate;
end $$;

create or replace function pg_temp.phase3_rls_test() returns table(test text, expected text, got text, verdict text)
language plpgsql as $$
declare
  email_a text := 'CHANGE_ME_shop_a@example.com';   -- <<< Shop A login email
  email_b text := 'CHANGE_ME_shop_b@example.com';   -- <<< Shop B login email
  ua uuid; ub uuid; ca uuid; cb uuid; role_b text; r text; names text;
begin
  select id into ua from auth.users where lower(email) = lower(email_a);
  select id into ub from auth.users where lower(email) = lower(email_b);
  if ua is null or ub is null then raise exception 'Could not find one of the two emails in auth.users. Edit email_a / email_b.'; end if;
  select company_id into ca from public.company_members where user_id = ua limit 1;
  select company_id, role into cb, role_b from public.company_members where user_id = ub limit 1;
  if ca is null or cb is null then raise exception 'One of the accounts has no shop yet (log in once first).'; end if;
  if ca = cb then raise exception 'Both emails belong to the same shop. Use two different shops.'; end if;

  delete from public.customers where customer_name like 'ZZ\_TEST%';
  delete from public.suppliers where supplier_name like 'ZZ\_TEST%';
  -- Seed as the table owner (bypasses RLS):
  insert into public.customers(company_id, customer_name, phone) values
    (ca, 'ZZ_TEST Ramesh', '9876543210'), (ca, 'ZZ_TEST Suresh', '9876543211'), (cb, 'ZZ_TEST Kumar', '9123456780');
  insert into public.suppliers(company_id, supplier_name, phone) values
    (ca, 'ZZ_TEST ABC Agro', '9876500000'), (cb, 'ZZ_TEST XYZ Traders', '9123400000');

  ---------------- Logged in as Shop A ----------------
  perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', ua::text, true);
  set local role authenticated;

  select string_agg(customer_name, ', ' order by customer_name) into names from public.customers where customer_name like 'ZZ\_TEST%';
  test := 'A sees only its customers'; expected := 'ZZ_TEST Ramesh, ZZ_TEST Suresh'; got := names; verdict := case when got = expected then 'PASS' else 'FAIL' end; return next;
  select string_agg(supplier_name, ', ') into names from public.suppliers where supplier_name like 'ZZ\_TEST%';
  test := 'A sees only its suppliers'; expected := 'ZZ_TEST ABC Agro'; got := names; verdict := case when got = expected then 'PASS' else 'FAIL' end; return next;
  test := 'A explicitly asks for B''s customers'; expected := 'OK rows=0'; got := pg_temp.try(format('select 1 from public.customers where company_id = %L', cb)); verdict := case when got = expected then 'PASS' else 'FAIL' end; return next;
  test := 'A SELECT B customers via filter (count)'; expected := '0'; select count(*)::text into got from public.customers where company_id = cb; verdict := case when got = expected then 'PASS' else 'FAIL' end; return next;
  test := 'A INSERT customer into B'; expected := 'ERR 42501'; got := pg_temp.try(format('insert into public.customers(company_id, customer_name, phone) values (%L, ''ZZ_TEST hack'', ''9000000000'')', cb)); verdict := case when got = expected then 'PASS' else 'FAIL' end; return next;
  test := 'A INSERT supplier into B'; expected := 'ERR 42501'; got := pg_temp.try(format('insert into public.suppliers(company_id, supplier_name, phone) values (%L, ''ZZ_TEST hack'', ''9000000000'')', cb)); verdict := case when got = expected then 'PASS' else 'FAIL' end; return next;
  test := 'A UPDATE B customer'; expected := 'OK rows=0'; got := pg_temp.try(format('update public.customers set city = ''Hacked'' where company_id = %L', cb)); verdict := case when got = expected then 'PASS' else 'FAIL' end; return next;
  test := 'A UPDATE B supplier'; expected := 'OK rows=0'; got := pg_temp.try(format('update public.suppliers set city = ''Hacked'' where company_id = %L', cb)); verdict := case when got = expected then 'PASS' else 'FAIL' end; return next;
  test := 'A DELETE B customer'; expected := 'ERR 42501'; got := pg_temp.try(format('delete from public.customers where company_id = %L', cb)); verdict := case when got = expected then 'PASS' else 'FAIL' end; return next;
  test := 'A DELETE own customer (no delete allowed)'; expected := 'ERR 42501'; got := pg_temp.try(format('delete from public.customers where company_id = %L', ca)); verdict := case when got = expected then 'PASS' else 'FAIL' end; return next;
  test := 'A moves own customer into B (change company_id)'; expected := 'ERR P0001'; got := pg_temp.try(format('update public.customers set company_id = %L where company_id = %L and customer_name = ''ZZ_TEST Ramesh''', cb, ca)); verdict := case when got = expected then 'PASS' else 'FAIL' end; return next;
  test := 'A edits own customer'; expected := 'OK rows=1'; got := pg_temp.try(format('update public.customers set city = ''Karur'' where company_id = %L and customer_name = ''ZZ_TEST Ramesh''', ca)); verdict := case when got = expected then 'PASS' else 'FAIL' end; return next;
  test := 'A adds valid own customer (messy phone/GST cleaned)'; expected := 'OK rows=1'; got := pg_temp.try(format('insert into public.customers(company_id, customer_name, phone, gst_number) values (%L, ''ZZ_TEST ok'', '' 98765 43212 '', ''33aabcu9603r1zx'')', ca)); verdict := case when got = expected then 'PASS' else 'FAIL' end; return next;
  test := 'A adds customer with bad phone'; expected := 'ERR 23514'; got := pg_temp.try(format('insert into public.customers(company_id, customer_name, phone) values (%L, ''ZZ_TEST bad'', ''123'')', ca)); verdict := case when got = expected then 'PASS' else 'FAIL' end; return next;
  test := 'A adds customer with negative balance'; expected := 'ERR 23514'; got := pg_temp.try(format('insert into public.customers(company_id, customer_name, phone, opening_balance) values (%L, ''ZZ_TEST neg'', ''9876543219'', -5)', ca)); verdict := case when got = expected then 'PASS' else 'FAIL' end; return next;
  test := 'A party_stats(B) is empty'; expected := '0'; select (public.party_stats(cb)->>'customers') into got; verdict := case when got = expected then 'PASS' else 'FAIL' end; return next;

  ---------------- Logged in as Shop B ----------------
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', ub::text, true);
  set local role authenticated;

  select string_agg(customer_name, ', ' order by customer_name) into names from public.customers where customer_name like 'ZZ\_TEST%';
  test := 'B sees only its customers'; expected := 'ZZ_TEST Kumar'; got := names; verdict := case when got = expected then 'PASS' else 'FAIL' end; return next;
  select string_agg(supplier_name, ', ') into names from public.suppliers where supplier_name like 'ZZ\_TEST%';
  test := 'B sees only its suppliers'; expected := 'ZZ_TEST XYZ Traders'; got := names; verdict := case when got = expected then 'PASS' else 'FAIL' end; return next;
  test := 'B INSERT customer into A'; expected := 'ERR 42501'; got := pg_temp.try(format('insert into public.customers(company_id, customer_name, phone) values (%L, ''ZZ_TEST hack'', ''9000000000'')', ca)); verdict := case when got = expected then 'PASS' else 'FAIL' end; return next;
  test := 'B UPDATE A customer'; expected := 'OK rows=0'; got := pg_temp.try(format('update public.customers set city = ''Hacked'' where company_id = %L', ca)); verdict := case when got = expected then 'PASS' else 'FAIL' end; return next;

  ---------------- Shop B demoted to cashier (reverted below) ----------------
  reset role;
  update public.company_members set role = 'cashier' where user_id = ub and company_id = cb;
  set local role authenticated;
  test := 'Cashier can still read customers'; expected := '1'; select count(*)::text into got from public.customers where customer_name like 'ZZ\_TEST%'; verdict := case when got = expected then 'PASS' else 'FAIL' end; return next;
  test := 'Cashier INSERT customer'; expected := 'ERR 42501'; got := pg_temp.try(format('insert into public.customers(company_id, customer_name, phone) values (%L, ''ZZ_TEST cashier'', ''9000000001'')', cb)); verdict := case when got = expected then 'PASS' else 'FAIL' end; return next;
  test := 'Cashier UPDATE own-shop customer'; expected := 'OK rows=0'; got := pg_temp.try(format('update public.customers set city = ''X'' where company_id = %L', cb)); verdict := case when got = expected then 'PASS' else 'FAIL' end; return next;
  test := 'Cashier INSERT supplier'; expected := 'ERR 42501'; got := pg_temp.try(format('insert into public.suppliers(company_id, supplier_name, phone) values (%L, ''ZZ_TEST cashier'', ''9000000001'')', cb)); verdict := case when got = expected then 'PASS' else 'FAIL' end; return next;

  ---------------- Not logged in (anon key only) ----------------
  reset role;
  set local role anon;
  test := 'Anonymous SELECT customers'; expected := 'ERR 42501'; got := pg_temp.try('select 1 from public.customers'); verdict := case when got = expected then 'PASS' else 'FAIL' end; return next;
  test := 'Anonymous INSERT supplier'; expected := 'ERR 42501'; got := pg_temp.try(format('insert into public.suppliers(company_id, supplier_name, phone) values (%L, ''ZZ_TEST anon'', ''9000000002'')', ca)); verdict := case when got = expected then 'PASS' else 'FAIL' end; return next;

  ---------------- Clean up ----------------
  reset role;
  update public.company_members set role = role_b where user_id = ub and company_id = cb;
  delete from public.customers where customer_name like 'ZZ\_TEST%';
  delete from public.suppliers where supplier_name like 'ZZ\_TEST%';
  test := 'Cleanup: Shop B role restored'; expected := role_b; select role into got from public.company_members where user_id = ub and company_id = cb; verdict := case when got = expected then 'PASS' else 'FAIL' end; return next;
  return;
end $$;

select * from pg_temp.phase3_rls_test();
