-- Agro POS — Phase 4 purchase test (functional + shop isolation). Run in the Supabase SQL Editor.
--
-- BEFORE RUNNING: replace the two emails below with the logins of two DIFFERENT shops (Shop A and Shop B), then Run.
-- You get one table of PASS/FAIL rows. The test creates 'ZZ_TEST ...' suppliers/products/purchases, checks stock,
-- supplier balance, cancel/edit rules and cross-shop attacks, then DELETES everything it created and restores the
-- purchase counter, so your next real purchase is still numbered normally. All in one transaction: any unexpected
-- error rolls the whole thing back.

create or replace function pg_temp.try(q text) returns text language plpgsql as $$
declare n bigint;
begin execute q; get diagnostics n = row_count; return 'OK rows=' || n;
exception when others then return 'ERR ' || sqlstate || ' ' || sqlerrm;
end $$;

create or replace function pg_temp.v(got text, expected text) returns text language sql as
$$ select case when got is not distinct from expected or got like expected then 'PASS' else 'FAIL' end $$;

create or replace function pg_temp.login(u uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', u::text, true);
  execute 'set local role authenticated';
end $$;

create or replace function pg_temp.phase4_test() returns table(test text, expected text, got text, verdict text)
language plpgsql as $$
declare
  email_a text := 'CHANGE_ME_shop_a@example.com';   -- <<< Shop A login email
  email_b text := 'CHANGE_ME_shop_b@example.com';   -- <<< Shop B login email
  ua uuid; ub uuid; ca uuid; cb uuid; role_b text; cat_a uuid; cat_b uuid;
  pa uuid; pb uuid; sa uuid; sb uuid; s_old uuid; ctr_a int; ctr_b int;
  j jsonb; p1 uuid; p1no text; p2 uuid; d1 uuid; c1 uuid; u1 uuid; m1 uuid; b1 uuid; t1 uuid; pbx uuid; bx uuid;
  n0 int; n1 int; inv numeric; r text;
begin
  select id into ua from auth.users where lower(email) = lower(email_a);
  select id into ub from auth.users where lower(email) = lower(email_b);
  if ua is null or ub is null then raise exception 'Could not find one of the two emails in auth.users. Edit email_a / email_b.'; end if;
  select company_id into ca from public.company_members where user_id = ua limit 1;
  select company_id, role into cb, role_b from public.company_members where user_id = ub limit 1;
  if ca is null or cb is null then raise exception 'One of the accounts has no shop yet (log in once first).'; end if;
  if ca = cb then raise exception 'Both emails belong to the same shop. Use two different shops.'; end if;

  select last_no into ctr_a from public.purchase_counters where company_id = ca;
  select last_no into ctr_b from public.purchase_counters where company_id = cb;

  -- leftovers from an interrupted earlier run
  delete from public.audit_logs where record_type = 'purchase' and record_id in (select id::text from public.purchases where supplier_id in (select id from public.suppliers where supplier_name like 'ZZ\_TEST%'));
  delete from public.purchases where supplier_id in (select id from public.suppliers where supplier_name like 'ZZ\_TEST%');
  delete from public.inventory_movements where product_id in (select id from public.products where product_name like 'ZZ\_TEST%');
  delete from public.products where product_name like 'ZZ\_TEST%';
  delete from public.categories where name like 'ZZ\_TEST%';
  delete from public.suppliers where supplier_name like 'ZZ\_TEST%';

  -- seed as table owner (bypasses RLS): one category, product, supplier per shop
  insert into public.categories(company_id, name) values (ca, 'ZZ_TEST Cat') returning id into cat_a;
  insert into public.categories(company_id, name) values (cb, 'ZZ_TEST Cat') returning id into cat_b;
  insert into public.products(company_id, category_id, product_name, unit) values (ca, cat_a, 'ZZ_TEST Urea', 'Kg') returning id into pa;
  insert into public.products(company_id, category_id, product_name, unit) values (cb, cat_b, 'ZZ_TEST Fertilizer B', 'Kg') returning id into pb;
  insert into public.inventory(company_id, product_id, quantity) values (ca, pa, 100), (cb, pb, 0);
  insert into public.product_batches(company_id, product_id, batch_number, quantity) values (ca, pa, 'OPENING', 100);
  insert into public.suppliers(company_id, supplier_name, phone) values (ca, 'ZZ_TEST ABC Agro', '9876500000') returning id into sa;
  insert into public.suppliers(company_id, supplier_name, phone, opening_balance, balance_type) values (cb, 'ZZ_TEST XYZ Agro', '9123400000', 500, 'debit') returning id into sb;
  insert into public.suppliers(company_id, supplier_name, phone, is_active) values (ca, 'ZZ_TEST Old Agro', '9876500001', false) returning id into s_old;

  ---------------- Shop A (owner) ----------------
  perform pg_temp.login(ua);

  -- Your scenario 1: Urea 100 kg, buy 50 kg @ 30, paid 500
  j := public.create_purchase(jsonb_build_object('company_id', ca, 'supplier_id', sa, 'invoice_number', 'INV-1001', 'status', 'completed', 'amount_paid', 500,
        'items', jsonb_build_array(jsonb_build_object('product_id', pa, 'quantity', 50, 'unit_price', 30))));
  p1 := (j->>'id')::uuid; p1no := j->>'purchase_no';
  test := 'P1 completed: total / paid / due / status'; expected := '1500.00|500.00|1000.00|partial|completed'; got := (select grand_total || '|' || amount_paid || '|' || balance_due || '|' || payment_status || '|' || status from public.purchases where id = p1); verdict := pg_temp.v(got, expected); return next;
  test := 'P1 first purchase number'; expected := case when ctr_a is null then 'PUR-000001' else '%' end; got := p1no; verdict := pg_temp.v(got, expected); return next;
  test := 'Urea stock 100 -> 150'; expected := '150.000'; select quantity::text into got from public.inventory where product_id = pa; verdict := pg_temp.v(got, expected); return next;
  test := 'Supplier outstanding = 1000'; expected := '1000.00'; select outstanding::text into got from public.supplier_outstanding(ca, array[sa]); verdict := pg_temp.v(got, expected); return next;
  test := 'Stock movement recorded (+50, purchase, ref = purchase no)'; expected := '50.000|purchase|150.000'; select quantity || '|' || movement_type || '|' || new_quantity into got from public.inventory_movements where product_id = pa and reference_id = p1no; verdict := pg_temp.v(got, expected); return next;
  test := 'Inventory equals sum of batches'; expected := 'true'; select ((select quantity from public.inventory where product_id = pa) = (select sum(quantity) from public.product_batches where product_id = pa))::text into got; verdict := pg_temp.v(got, expected); return next;

  -- Your scenario 2: another 25 kg @ 32, paid 800
  j := public.create_purchase(jsonb_build_object('company_id', ca, 'supplier_id', sa, 'invoice_number', 'INV-1002', 'status', 'completed', 'amount_paid', 800,
        'items', jsonb_build_array(jsonb_build_object('product_id', pa, 'quantity', 25, 'unit_price', 32))));
  p2 := (j->>'id')::uuid;
  test := 'P2 separate purchase; stock 150 -> 175'; expected := '175.000|2'; select (select quantity::text from public.inventory where product_id = pa) || '|' || (select count(*) from public.purchases where supplier_id = sa and status = 'completed') into got; verdict := pg_temp.v(got, expected); return next;
  test := 'Outstanding still 1000 (P2 fully paid)'; expected := '1000.00'; select outstanding::text into got from public.supplier_outstanding(ca, array[sa]); verdict := pg_temp.v(got, expected); return next;
  test := 'Duplicate invoice, same supplier, rejected'; expected := 'ERR 23505%'; got := pg_temp.try(format('select public.create_purchase(%L::jsonb)', jsonb_build_object('company_id', ca, 'supplier_id', sa, 'invoice_number', 'inv-1001', 'status', 'draft', 'items', jsonb_build_array(jsonb_build_object('product_id', pa, 'quantity', 1, 'unit_price', 1))))); verdict := pg_temp.v(got, expected); return next;

  -- Draft does not touch stock; completing it does
  j := public.create_purchase(jsonb_build_object('company_id', ca, 'supplier_id', sa, 'status', 'draft', 'items', jsonb_build_array(jsonb_build_object('product_id', pa, 'quantity', 10, 'unit_price', 30))));
  d1 := (j->>'id')::uuid;
  test := 'Draft: stock unchanged, not in supplier balance'; expected := '175.000|1000.00'; select (select quantity::text from public.inventory where product_id = pa) || '|' || (select outstanding::text from public.supplier_outstanding(ca, array[sa])) into got; verdict := pg_temp.v(got, expected); return next;
  perform public.update_purchase(d1, jsonb_build_object('supplier_id', sa, 'status', 'completed', 'items', jsonb_build_array(jsonb_build_object('product_id', pa, 'quantity', 10, 'unit_price', 30))));
  test := 'Draft completed: stock 185, outstanding 1300'; expected := '185.000|1300.00'; select (select quantity::text from public.inventory where product_id = pa) || '|' || (select outstanding::text from public.supplier_outstanding(ca, array[sa])) into got; verdict := pg_temp.v(got, expected); return next;

  -- Edit completed purchase 50 -> 70 kg: only the +20 difference is added (no doubling)
  perform public.update_purchase(p1, jsonb_build_object('supplier_id', sa, 'invoice_number', 'INV-1001', 'amount_paid', 500,
        'items', jsonb_build_array(jsonb_build_object('product_id', pa, 'quantity', 70, 'unit_price', 30))));
  test := 'Edit 50->70 kg: stock 185 -> 205 (not 255)'; expected := '205.000'; select quantity::text into got from public.inventory where product_id = pa; verdict := pg_temp.v(got, expected); return next;
  test := 'Edit recorded as net +20 (2 movements, sum 70)'; expected := '2|70.000'; select count(*) || '|' || sum(quantity) into got from public.inventory_movements where product_id = pa and reference_id = p1no; verdict := pg_temp.v(got, expected); return next;
  test := 'Edit: due recomputed 2100-500=1600'; expected := '2100.00|1600.00'; select grand_total || '|' || balance_due into got from public.purchases where id = p1; verdict := pg_temp.v(got, expected); return next;
  perform public.update_purchase(p1, jsonb_build_object('supplier_id', sa, 'invoice_number', 'INV-1001', 'amount_paid', 2100,
        'items', jsonb_build_array(jsonb_build_object('product_id', pa, 'quantity', 70, 'unit_price', 30))));
  test := 'Payment-only edit: no stock change, no new movement'; expected := '205.000|2|paid|300.00'; select (select quantity::text from public.inventory where product_id = pa) || '|' || (select count(*) from public.inventory_movements where product_id = pa and reference_id = p1no) || '|' || (select payment_status from public.purchases where id = p1) || '|' || (select outstanding::text from public.supplier_outstanding(ca, array[sa])) into got; verdict := pg_temp.v(got, expected); return next;

  -- Cancel: stock and balance reversed, record kept
  j := public.create_purchase(jsonb_build_object('company_id', ca, 'supplier_id', sa, 'invoice_number', 'INV-C1', 'status', 'completed',
        'items', jsonb_build_array(jsonb_build_object('product_id', pa, 'quantity', 50, 'unit_price', 30))));
  c1 := (j->>'id')::uuid;
  test := 'Before cancel: stock 255, outstanding 1800'; expected := '255.000|1800.00'; select (select quantity::text from public.inventory where product_id = pa) || '|' || (select outstanding::text from public.supplier_outstanding(ca, array[sa])) into got; verdict := pg_temp.v(got, expected); return next;
  perform public.cancel_purchase(c1, 'test');
  test := 'Cancel: status cancelled, stock 205, outstanding 300'; expected := 'cancelled|205.000|300.00'; select (select status from public.purchases where id = c1) || '|' || (select quantity::text from public.inventory where product_id = pa) || '|' || (select outstanding::text from public.supplier_outstanding(ca, array[sa])) into got; verdict := pg_temp.v(got, expected); return next;
  test := 'Cancel wrote a reversal movement (-50, purchase_return)'; expected := '-50.000|purchase_return'; select quantity || '|' || movement_type into got from public.inventory_movements where product_id = pa and reference_id = (select purchase_no from public.purchases where id = c1) and quantity < 0; verdict := pg_temp.v(got, expected); return next;
  test := 'Cancel twice refused'; expected := 'ERR P0001 ALREADY_CANCELLED'; got := pg_temp.try(format('select public.cancel_purchase(%L)', c1)); verdict := pg_temp.v(got, expected); return next;
  test := 'Edit a cancelled purchase refused'; expected := 'ERR P0001 PURCHASE_CANCELLED'; got := pg_temp.try(format('select public.update_purchase(%L, %L::jsonb)', c1, jsonb_build_object('supplier_id', sa, 'items', jsonb_build_array(jsonb_build_object('product_id', pa, 'quantity', 1, 'unit_price', 1))))); verdict := pg_temp.v(got, expected); return next;
  test := 'Cancelled invoice number can be reused'; expected := 'OK rows=1'; got := pg_temp.try(format('select public.create_purchase(%L::jsonb)', jsonb_build_object('company_id', ca, 'supplier_id', sa, 'invoice_number', 'INV-C1', 'status', 'draft', 'items', jsonb_build_array(jsonb_build_object('product_id', pa, 'quantity', 1, 'unit_price', 1))))); verdict := pg_temp.v(got, expected); return next;

  -- Stock already used: cancel is refused and NOTHING changes
  j := public.create_purchase(jsonb_build_object('company_id', ca, 'supplier_id', sa, 'status', 'completed',
        'items', jsonb_build_array(jsonb_build_object('product_id', pa, 'quantity', 10, 'unit_price', 30, 'batch_number', 'BX'))));
  u1 := (j->>'id')::uuid;
  select id into bx from public.product_batches where company_id = ca and product_id = pa and batch_number = 'BX';
  perform public.adjust_stock(pa, bx, 'decrease', 8, 'test sold');
  test := 'Sold stock: cancel refused'; expected := 'ERR P0001 INSUFFICIENT_STOCK'; got := pg_temp.try(format('select public.cancel_purchase(%L)', u1)); verdict := pg_temp.v(got, expected); return next;
  test := 'Refused cancel left purchase + stock untouched'; expected := 'completed|207.000'; select (select status from public.purchases where id = u1) || '|' || (select quantity::text from public.inventory where product_id = pa) into got; verdict := pg_temp.v(got, expected); return next;
  test := 'Edit cannot shrink below what is left (10->5)'; expected := 'ERR P0001 INSUFFICIENT_STOCK'; got := pg_temp.try(format('select public.update_purchase(%L, %L::jsonb)', u1, jsonb_build_object('supplier_id', sa, 'items', jsonb_build_array(jsonb_build_object('product_id', pa, 'quantity', 5, 'unit_price', 30, 'batch_number', 'BX'))))); verdict := pg_temp.v(got, expected); return next;
  perform public.update_purchase(u1, jsonb_build_object('supplier_id', sa, 'items', jsonb_build_array(jsonb_build_object('product_id', pa, 'quantity', 12, 'unit_price', 30, 'batch_number', 'BX'))));
  test := 'Edit may grow it (10->12): stock 207 -> 209'; expected := '209.000'; select quantity::text into got from public.inventory where product_id = pa; verdict := pg_temp.v(got, expected); return next;

  -- Atomicity: failure AFTER the first line already moved stock must roll everything back
  j := public.create_purchase(jsonb_build_object('company_id', ca, 'supplier_id', sa, 'status', 'completed',
        'items', jsonb_build_array(jsonb_build_object('product_id', pa, 'quantity', 5, 'unit_price', 30, 'batch_number', 'M1', 'expiry_date', '2027-01-01'))));
  m1 := (j->>'id')::uuid;
  select count(*) into n0 from public.purchases where supplier_id = sa; select quantity into inv from public.inventory where product_id = pa;
  got := pg_temp.try(format('select public.create_purchase(%L::jsonb)', jsonb_build_object('company_id', ca, 'supplier_id', sa, 'status', 'completed',
        'items', jsonb_build_array(jsonb_build_object('product_id', pa, 'quantity', 5, 'unit_price', 30, 'batch_number', 'M0'),
                                   jsonb_build_object('product_id', pa, 'quantity', 5, 'unit_price', 30, 'batch_number', 'M1', 'expiry_date', '2028-01-01')))));
  test := 'Mid-way failure is refused'; expected := 'ERR P0001 BATCH_DATE_MISMATCH'; verdict := pg_temp.v(got, expected); return next;
  select count(*) into n1 from public.purchases where supplier_id = sa;
  test := 'Mid-way failure: no purchase, no stock, no stray batch'; expected := 'true|true|0'; got := (n0 = n1)::text || '|' || ((select quantity from public.inventory where product_id = pa) = inv)::text || '|' || (select count(*) from public.product_batches where product_id = pa and batch_number = 'M0'); verdict := pg_temp.v(got, expected); return next;
  test := 'Failed items (bad product) create nothing'; expected := 'ERR P0001 PRODUCT_NOT_FOUND'; got := pg_temp.try(format('select public.create_purchase(%L::jsonb)', jsonb_build_object('company_id', ca, 'supplier_id', sa, 'status', 'completed', 'items', jsonb_build_array(jsonb_build_object('product_id', pa, 'quantity', 5, 'unit_price', 1), jsonb_build_object('product_id', pb, 'quantity', 5, 'unit_price', 1))))); verdict := pg_temp.v(got, expected); return next;
  test := 'Atomic: purchase count + stock unchanged after that'; expected := 'true'; select ((select count(*) from public.purchases where supplier_id = sa) = n0 and (select quantity from public.inventory where product_id = pa) = inv)::text into got; verdict := pg_temp.v(got, expected); return next;

  -- Money maths (draft, so stock is not touched): 10 x 33.33 - 3.30 = 330.00; GST 18% = 59.40; -10 discount +25 charges
  j := public.create_purchase(jsonb_build_object('company_id', ca, 'supplier_id', sa, 'status', 'draft', 'discount', 10, 'additional_charges', 25,
        'items', jsonb_build_array(jsonb_build_object('product_id', pa, 'quantity', 10, 'unit_price', 33.33, 'discount', 3.30, 'tax_rate', 18))));
  t1 := (j->>'id')::uuid;
  test := 'Totals: subtotal|tax|grand|due'; expected := '330.00|59.40|404.40|404.40'; select subtotal || '|' || tax || '|' || grand_total || '|' || balance_due into got from public.purchases where id = t1; verdict := pg_temp.v(got, expected); return next;

  -- Validation
  test := 'Quantity 0 rejected'; expected := 'ERR P0001 INVALID_QUANTITY'; got := pg_temp.try(format('select public.create_purchase(%L::jsonb)', jsonb_build_object('company_id', ca, 'supplier_id', sa, 'items', jsonb_build_array(jsonb_build_object('product_id', pa, 'quantity', 0, 'unit_price', 1))))); verdict := pg_temp.v(got, expected); return next;
  test := 'No items rejected'; expected := 'ERR P0001 NO_ITEMS'; got := pg_temp.try(format('select public.create_purchase(%L::jsonb)', jsonb_build_object('company_id', ca, 'supplier_id', sa, 'items', jsonb_build_array()))); verdict := pg_temp.v(got, expected); return next;
  test := 'Paid more than total rejected'; expected := 'ERR P0001 PAID_EXCEEDS_TOTAL'; got := pg_temp.try(format('select public.create_purchase(%L::jsonb)', jsonb_build_object('company_id', ca, 'supplier_id', sa, 'amount_paid', 999, 'items', jsonb_build_array(jsonb_build_object('product_id', pa, 'quantity', 1, 'unit_price', 10))))); verdict := pg_temp.v(got, expected); return next;
  test := 'Inactive supplier rejected'; expected := 'ERR P0001 SUPPLIER_INACTIVE'; got := pg_temp.try(format('select public.create_purchase(%L::jsonb)', jsonb_build_object('company_id', ca, 'supplier_id', s_old, 'items', jsonb_build_array(jsonb_build_object('product_id', pa, 'quantity', 1, 'unit_price', 10))))); verdict := pg_temp.v(got, expected); return next;
  test := 'More than 2 decimals on money rejected'; expected := 'ERR P0001 INVALID_AMOUNT'; got := pg_temp.try(format('select public.create_purchase(%L::jsonb)', jsonb_build_object('company_id', ca, 'supplier_id', sa, 'items', jsonb_build_array(jsonb_build_object('product_id', pa, 'quantity', 1, 'unit_price', 10.005))))); verdict := pg_temp.v(got, expected); return next;

  -- Direct table writes are impossible (must use the functions)
  test := 'Direct INSERT into purchases blocked'; expected := 'ERR 42501%'; got := pg_temp.try(format('insert into public.purchases(company_id, supplier_id, purchase_no) values (%L, %L, ''PUR-999999'')', ca, sa)); verdict := pg_temp.v(got, expected); return next;
  test := 'Direct UPDATE of purchases blocked'; expected := 'ERR 42501%'; got := pg_temp.try(format('update public.purchases set status = ''completed'' where id = %L', d1)); verdict := pg_temp.v(got, expected); return next;
  test := 'Direct DELETE of purchases blocked'; expected := 'ERR 42501%'; got := pg_temp.try(format('delete from public.purchases where id = %L', p1)); verdict := pg_temp.v(got, expected); return next;
  test := 'Direct INSERT into purchase_items blocked'; expected := 'ERR 42501%'; got := pg_temp.try(format('insert into public.purchase_items(purchase_id, company_id, line_no, product_id, quantity, unit_price, line_total, batch_number) values (%L, %L, 99, %L, 1, 1, 1, ''X'')', p1, ca, pa)); verdict := pg_temp.v(got, expected); return next;
  test := 'Purchase counter table not readable'; expected := 'ERR 42501%'; got := pg_temp.try('select * from public.purchase_counters'); verdict := pg_temp.v(got, expected); return next;
  test := 'Internal helper functions not callable'; expected := 'ERR 42501%'; got := pg_temp.try(format('select public.purchase_upsert(null::uuid, %L::jsonb)', jsonb_build_object('company_id', ca))); verdict := pg_temp.v(got, expected); return next;

  ---------------- Shop B (owner) ----------------
  reset role; perform pg_temp.login(ub);
  j := public.create_purchase(jsonb_build_object('company_id', cb, 'supplier_id', sb, 'invoice_number', 'INV-1001', 'status', 'completed', 'amount_paid', 700,
        'items', jsonb_build_array(jsonb_build_object('product_id', pb, 'quantity', 50, 'unit_price', 20))));
  pbx := (j->>'id')::uuid;
  test := 'B: same invoice number as A is fine; stock 0 -> 50'; expected := '50.000'; select quantity::text into got from public.inventory where product_id = pb; verdict := pg_temp.v(got, expected); return next;
  test := 'B outstanding = -500 advance + 300 due = -200'; expected := '-200.00'; select outstanding::text into got from public.supplier_outstanding(cb, array[sb]); verdict := pg_temp.v(got, expected); return next;
  test := 'B sees only its own purchases'; expected := '1'; select count(*)::text into got from public.purchases where supplier_id in (select id from public.suppliers where supplier_name like 'ZZ\_TEST%'); verdict := pg_temp.v(got, expected); return next;
  test := 'B sees none of A''s purchases / items / inventory'; expected := '0|0|0'; select (select count(*) from public.purchases where company_id = ca) || '|' || (select count(*) from public.purchase_items where company_id = ca) || '|' || (select count(*) from public.inventory where company_id = ca) into got; verdict := pg_temp.v(got, expected); return next;
  test := 'B supplier_outstanding(A) is empty'; expected := '0'; select count(*)::text into got from public.supplier_outstanding(ca); verdict := pg_temp.v(got, expected); return next;
  test := 'B UPDATE A''s purchase refused'; expected := 'ERR P0001 NOT_ALLOWED'; got := pg_temp.try(format('select public.update_purchase(%L, %L::jsonb)', p1, jsonb_build_object('supplier_id', sb, 'items', jsonb_build_array(jsonb_build_object('product_id', pb, 'quantity', 1, 'unit_price', 1))))); verdict := pg_temp.v(got, expected); return next;
  test := 'B CANCEL A''s purchase refused'; expected := 'ERR P0001 NOT_ALLOWED'; got := pg_temp.try(format('select public.cancel_purchase(%L)', p1)); verdict := pg_temp.v(got, expected); return next;
  test := 'B creates a purchase inside A (company_id = A)'; expected := 'ERR P0001 NOT_ALLOWED'; got := pg_temp.try(format('select public.create_purchase(%L::jsonb)', jsonb_build_object('company_id', ca, 'supplier_id', sa, 'items', jsonb_build_array(jsonb_build_object('product_id', pa, 'quantity', 1, 'unit_price', 1))))); verdict := pg_temp.v(got, expected); return next;
  test := 'B uses A''s supplier in its own purchase'; expected := 'ERR P0001 SUPPLIER_NOT_FOUND'; got := pg_temp.try(format('select public.create_purchase(%L::jsonb)', jsonb_build_object('company_id', cb, 'supplier_id', sa, 'items', jsonb_build_array(jsonb_build_object('product_id', pb, 'quantity', 1, 'unit_price', 1))))); verdict := pg_temp.v(got, expected); return next;
  test := 'B uses A''s product in its own purchase'; expected := 'ERR P0001 PRODUCT_NOT_FOUND'; got := pg_temp.try(format('select public.create_purchase(%L::jsonb)', jsonb_build_object('company_id', cb, 'supplier_id', sb, 'items', jsonb_build_array(jsonb_build_object('product_id', pa, 'quantity', 1, 'unit_price', 1))))); verdict := pg_temp.v(got, expected); return next;

  ---------------- Shop A again: sees nothing of B ----------------
  reset role; perform pg_temp.login(ua);
  test := 'A sees none of B''s purchases / items / inventory'; expected := '0|0|0'; select (select count(*) from public.purchases where company_id = cb) || '|' || (select count(*) from public.purchase_items where company_id = cb) || '|' || (select count(*) from public.inventory where company_id = cb) into got; verdict := pg_temp.v(got, expected); return next;
  test := 'A CANCEL B''s purchase refused'; expected := 'ERR P0001 NOT_ALLOWED'; got := pg_temp.try(format('select public.cancel_purchase(%L)', pbx)); verdict := pg_temp.v(got, expected); return next;
  test := 'A creates a purchase inside B (company_id = B)'; expected := 'ERR P0001 NOT_ALLOWED'; got := pg_temp.try(format('select public.create_purchase(%L::jsonb)', jsonb_build_object('company_id', cb, 'supplier_id', sb, 'items', jsonb_build_array(jsonb_build_object('product_id', pb, 'quantity', 1, 'unit_price', 1))))); verdict := pg_temp.v(got, expected); return next;
  test := 'A uses B''s supplier in its own purchase'; expected := 'ERR P0001 SUPPLIER_NOT_FOUND'; got := pg_temp.try(format('select public.create_purchase(%L::jsonb)', jsonb_build_object('company_id', ca, 'supplier_id', sb, 'items', jsonb_build_array(jsonb_build_object('product_id', pa, 'quantity', 1, 'unit_price', 1))))); verdict := pg_temp.v(got, expected); return next;
  test := 'A stock untouched by B''s purchase'; expected := '214.000'; select quantity::text into got from public.inventory where product_id = pa; verdict := pg_temp.v(got, expected); return next;

  ---------------- Shop B demoted to cashier (reverted below) ----------------
  reset role;
  update public.company_members set role = 'cashier' where user_id = ub and company_id = cb;
  perform pg_temp.login(ub);
  test := 'Cashier can read purchases'; expected := '1'; select count(*)::text into got from public.purchases where supplier_id = sb; verdict := pg_temp.v(got, expected); return next;
  test := 'Cashier cannot create'; expected := 'ERR P0001 NOT_ALLOWED'; got := pg_temp.try(format('select public.create_purchase(%L::jsonb)', jsonb_build_object('company_id', cb, 'supplier_id', sb, 'items', jsonb_build_array(jsonb_build_object('product_id', pb, 'quantity', 1, 'unit_price', 1))))); verdict := pg_temp.v(got, expected); return next;
  test := 'Cashier cannot cancel'; expected := 'ERR P0001 NOT_ALLOWED'; got := pg_temp.try(format('select public.cancel_purchase(%L)', pbx)); verdict := pg_temp.v(got, expected); return next;

  ---------------- Not logged in ----------------
  reset role; set local role anon;
  test := 'Anonymous cannot read purchases'; expected := 'ERR 42501%'; got := pg_temp.try('select 1 from public.purchases'); verdict := pg_temp.v(got, expected); return next;
  test := 'Anonymous cannot call create_purchase'; expected := 'ERR 42501%'; got := pg_temp.try(format('select public.create_purchase(%L::jsonb)', jsonb_build_object('company_id', ca))); verdict := pg_temp.v(got, expected); return next;
  test := 'Anonymous cannot read supplier balances'; expected := 'ERR 42501%'; got := pg_temp.try(format('select * from public.supplier_outstanding(%L)', ca)); verdict := pg_temp.v(got, expected); return next;

  ---------------- Clean up everything this test created ----------------
  reset role;
  update public.company_members set role = role_b where user_id = ub and company_id = cb;
  delete from public.audit_logs where record_type = 'purchase' and record_id in (select id::text from public.purchases where supplier_id in (select id from public.suppliers where supplier_name like 'ZZ\_TEST%'));
  delete from public.purchases where supplier_id in (select id from public.suppliers where supplier_name like 'ZZ\_TEST%');
  delete from public.inventory_movements where product_id in (select id from public.products where product_name like 'ZZ\_TEST%');
  delete from public.products where product_name like 'ZZ\_TEST%';
  delete from public.categories where name like 'ZZ\_TEST%';
  delete from public.suppliers where supplier_name like 'ZZ\_TEST%';
  if ctr_a is null then delete from public.purchase_counters where company_id = ca; else update public.purchase_counters set last_no = ctr_a where company_id = ca; end if;
  if ctr_b is null then delete from public.purchase_counters where company_id = cb; else update public.purchase_counters set last_no = ctr_b where company_id = cb; end if;
  test := 'Cleanup: no test data left, Shop B role restored'; expected := '0|0|0|' || role_b;
  got := (select count(*) from public.purchases where supplier_id in (select id from public.suppliers where supplier_name like 'ZZ\_TEST%')) || '|' || (select count(*) from public.products where product_name like 'ZZ\_TEST%') || '|' || (select count(*) from public.suppliers where supplier_name like 'ZZ\_TEST%') || '|' || (select role from public.company_members where user_id = ub and company_id = cb);
  verdict := pg_temp.v(got, expected); return next;
  return;
end $$;

select * from pg_temp.phase4_test();
