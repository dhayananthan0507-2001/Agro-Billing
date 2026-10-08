-- Agro POS — Phase 5 sales test (functional + shop isolation). Run in the Supabase SQL Editor.
--
-- BEFORE RUNNING: replace the two emails below with the logins of two DIFFERENT shops (Shop A and Shop B), then Run.
-- You get one table of PASS/FAIL rows. The test creates 'ZZ_TEST ...' products/customers/sales, checks stock, batches,
-- invoice numbers, payments, edit/cancel rules, roles and cross-shop attacks, then DELETES everything it created and
-- restores the invoice/purchase counters, so your next real invoice keeps its normal number. One transaction: any
-- unexpected error rolls the whole thing back. Your real products, stock and sales are never touched.

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

create or replace function pg_temp.item(pid uuid, qty numeric, price numeric default 60, disc numeric default 0) returns jsonb language sql as
$$ select jsonb_build_object('product_id', pid, 'quantity', qty, 'unit_price', price, 'discount', disc) $$;

create or replace function pg_temp.stock(pid uuid) returns text language sql as $$ select quantity::text from public.inventory where product_id = pid $$;

create or replace function pg_temp.sale(cid uuid, items jsonb, paid numeric, extra jsonb default '{}'::jsonb) returns jsonb language sql as
$$ select public.create_sale(jsonb_build_object('company_id', cid, 'notes', 'ZZ_TEST', 'payment_method', 'cash', 'amount_paid', paid, 'items', items) || extra) $$;

create or replace function pg_temp.phase5_test() returns table(test text, expected text, got text, verdict text)
language plpgsql as $$
declare
  email_a text := 'CHANGE_ME_shop_a@example.com';   -- <<< Shop A login email
  email_b text := 'CHANGE_ME_shop_b@example.com';   -- <<< Shop B login email
  ua uuid; ub uuid; ca uuid; cb uuid; role_b text; cat_a uuid; cat_b uuid; today date := public.today_ist();
  pr uuid; pw uuid; pc uuid; psd uuid; po uuid; pt uuid; pbr uuid;           -- rice, wheat, chain, seed, oil, tax18 (all shop A); rice (shop B)
  cr uuid; c_old uuid; ck uuid; sa uuid; b_soon uuid; b_late uuid; b_exp uuid; b_none uuid;
  ctr_sa int; ctr_sb int; ctr_pa int; ctr_pb int; st0 jsonb; st1 jsonb;
  j jsonb; s1 uuid; s2 uuid; s4 uuid; scr uuid; sup uuid; sfe uuid; sdec uuid; stx uuid; sb1 uuid; pur uuid; n0 int; n1 int; inv0 numeric; x text;
begin
  select id into ua from auth.users where lower(email) = lower(email_a);
  select id into ub from auth.users where lower(email) = lower(email_b);
  if ua is null or ub is null then raise exception 'Could not find one of the two emails in auth.users. Edit email_a / email_b.'; end if;
  select company_id into ca from public.company_members where user_id = ua limit 1;
  select company_id, role into cb, role_b from public.company_members where user_id = ub limit 1;
  if ca is null or cb is null then raise exception 'One of the accounts has no shop yet (log in once first).'; end if;
  if ca = cb then raise exception 'Both emails belong to the same shop. Use two different shops.'; end if;

  select last_no into ctr_sa from public.sale_counters where company_id = ca;     select last_no into ctr_sb from public.sale_counters where company_id = cb;
  select last_no into ctr_pa from public.purchase_counters where company_id = ca; select last_no into ctr_pb from public.purchase_counters where company_id = cb;

  -- leftovers from an interrupted earlier run
  delete from public.audit_logs where (record_type = 'sale' and record_id in (select id::text from public.sales where notes like 'ZZ\_TEST%'))
     or (record_type = 'purchase' and record_id in (select id::text from public.purchases where notes like 'ZZ\_TEST%'));
  delete from public.sales where notes like 'ZZ\_TEST%';
  delete from public.purchases where notes like 'ZZ\_TEST%';
  delete from public.inventory_movements where product_id in (select id from public.products where product_name like 'ZZ\_TEST%');
  delete from public.products where product_name like 'ZZ\_TEST%';
  delete from public.categories where name like 'ZZ\_TEST%';
  delete from public.customers where customer_name like 'ZZ\_TEST%';
  delete from public.suppliers where supplier_name like 'ZZ\_TEST%';

  -- seed as table owner (bypasses RLS)
  insert into public.categories(company_id, name) values (ca, 'ZZ_TEST Cat') returning id into cat_a;
  insert into public.categories(company_id, name) values (cb, 'ZZ_TEST Cat') returning id into cat_b;
  insert into public.products(company_id, category_id, product_name, unit, selling_price, tax_rate) values (ca, cat_a, 'ZZ_TEST Rice', 'Kg', 60, 0) returning id into pr;
  insert into public.products(company_id, category_id, product_name, unit, selling_price, tax_rate) values (ca, cat_a, 'ZZ_TEST Wheat', 'Kg', 40, 5) returning id into pw;
  insert into public.products(company_id, category_id, product_name, unit, selling_price, tax_rate) values (ca, cat_a, 'ZZ_TEST Chain', 'Kg', 10, 0) returning id into pc;
  insert into public.products(company_id, category_id, product_name, unit, selling_price, tax_rate) values (ca, cat_a, 'ZZ_TEST Seed', 'Kg', 100, 0) returning id into psd;
  insert into public.products(company_id, category_id, product_name, unit, selling_price, tax_rate) values (ca, cat_a, 'ZZ_TEST Oil', 'Litre', 120, 0) returning id into po;
  insert into public.products(company_id, category_id, product_name, unit, selling_price, tax_rate) values (ca, cat_a, 'ZZ_TEST Tax18', 'Kg', 33.33, 18) returning id into pt;
  insert into public.products(company_id, category_id, product_name, unit, selling_price, tax_rate) values (cb, cat_b, 'ZZ_TEST Rice B', 'Kg', 60, 0) returning id into pbr;
  insert into public.inventory(company_id, product_id, quantity) values (ca, pr, 100), (ca, pw, 50), (ca, pc, 100), (ca, psd, 40), (ca, po, 10), (ca, pt, 100), (cb, pbr, 50);
  insert into public.product_batches(company_id, product_id, batch_number, quantity) values (ca, pr, 'OPENING', 100), (ca, pw, 'OPENING', 50), (ca, pc, 'OPENING', 100), (ca, po, 'OPENING', 10), (ca, pt, 'OPENING', 100), (cb, pbr, 'OPENING', 50);
  insert into public.product_batches(company_id, product_id, batch_number, quantity, expiry_date) values (ca, psd, 'SOON', 10, today + 10) returning id into b_soon;
  insert into public.product_batches(company_id, product_id, batch_number, quantity, expiry_date) values (ca, psd, 'LATE', 10, today + 100) returning id into b_late;
  insert into public.product_batches(company_id, product_id, batch_number, quantity, expiry_date) values (ca, psd, 'EXPIRED', 10, today - 5) returning id into b_exp;
  insert into public.product_batches(company_id, product_id, batch_number, quantity) values (ca, psd, 'NOEXP', 10) returning id into b_none;
  insert into public.customers(company_id, customer_name, phone, opening_balance, balance_type) values (ca, 'ZZ_TEST Ramesh', '9876543210', 200, 'debit') returning id into cr;
  insert into public.customers(company_id, customer_name, phone, is_active) values (ca, 'ZZ_TEST Old', '9876543211', false) returning id into c_old;
  insert into public.customers(company_id, customer_name, phone) values (cb, 'ZZ_TEST Kumar', '9123456780') returning id into ck;
  insert into public.suppliers(company_id, supplier_name, phone) values (ca, 'ZZ_TEST ABC Agro', '9876500000') returning id into sa;

  ---------------- Shop A (owner) ----------------
  perform pg_temp.login(ua);
  st0 := public.sale_stats(ca, today);

  -- TEST 1: basic sale 25 kg of 100
  j := pg_temp.sale(ca, jsonb_build_array(pg_temp.item(pr, 25)), 1500);
  s1 := (j->>'id')::uuid;
  test := 'T1 sale created: total / status'; expected := '1500.00|paid|completed'; got := (select grand_total || '|' || payment_status || '|' || status from public.sales where id = s1); verdict := pg_temp.v(got, expected); return next;
  test := 'T1 stock 100 -> 75'; expected := '75.000'; got := pg_temp.stock(pr); verdict := pg_temp.v(got, expected); return next;
  test := 'T1 first invoice number'; expected := '%-' || lpad((coalesce(ctr_sa, 0) + 1)::text, 6, '0'); got := j->>'invoice_no'; verdict := pg_temp.v(got, expected); return next;
  test := 'T1 stock history: -25 sale, ref = invoice'; expected := '-25.000|sale|75.000'; select quantity || '|' || movement_type || '|' || new_quantity into got from public.inventory_movements where product_id = pr and reference_id = j->>'invoice_no'; verdict := pg_temp.v(got, expected); return next;
  test := 'T1 inventory equals sum of batches'; expected := 'true'; got := ((select quantity from public.inventory where product_id = pr) = (select sum(quantity) from public.product_batches where product_id = pr))::text; verdict := pg_temp.v(got, expected); return next;

  -- TEST 2: two products on one invoice (Wheat has 5% GST: 5 x 40 = 200 + 10)
  j := pg_temp.sale(ca, jsonb_build_array(pg_temp.item(pr, 10), pg_temp.item(pw, 5, 40)), 810);
  s2 := (j->>'id')::uuid;
  test := 'T2 two lines, total 600 + 210 = 810'; expected := '2|810.00|10.00'; got := (select count(*) from public.sale_items where sale_id = s2) || '|' || (select grand_total from public.sales where id = s2) || '|' || (select tax from public.sales where id = s2); verdict := pg_temp.v(got, expected); return next;
  test := 'T2 both stocks reduced: Rice 65, Wheat 45'; expected := '65.000|45.000'; got := pg_temp.stock(pr) || '|' || pg_temp.stock(pw); verdict := pg_temp.v(got, expected); return next;
  test := 'T2 sequential invoice number'; expected := '%-' || lpad((coalesce(ctr_sa, 0) + 2)::text, 6, '0'); got := j->>'invoice_no'; verdict := pg_temp.v(got, expected); return next;

  -- TEST 3: insufficient stock, including rollback when a LATER line fails
  select count(*) into n0 from public.sales where notes like 'ZZ\_TEST%';
  test := 'T3 sell 50 when 45 left is refused'; expected := 'ERR P0001 INSUFFICIENT_STOCK'; got := pg_temp.try(format('select pg_temp.sale(%L, %L::jsonb, 2100)', ca, jsonb_build_array(pg_temp.item(pw, 50, 40)))); verdict := pg_temp.v(got, expected); return next;
  got := pg_temp.try(format('select pg_temp.sale(%L, %L::jsonb, 0, %L::jsonb)', ca, jsonb_build_array(pg_temp.item(pr, 5), pg_temp.item(pw, 100, 40)), jsonb_build_object('customer_id', cr)));
  test := 'T3 first line fine, second too big: refused'; expected := 'ERR P0001 INSUFFICIENT_STOCK'; verdict := pg_temp.v(got, expected); return next;
  select count(*) into n1 from public.sales where notes like 'ZZ\_TEST%';
  test := 'T3 nothing saved, no stock moved (Rice 65, Wheat 45)'; expected := 'true|65.000|45.000'; got := (n0 = n1)::text || '|' || pg_temp.stock(pr) || '|' || pg_temp.stock(pw); verdict := pg_temp.v(got, expected); return next;

  -- TEST 4: edit 20 -> 15 returns 5
  j := pg_temp.sale(ca, jsonb_build_array(pg_temp.item(pr, 20)), 1200); s4 := (j->>'id')::uuid;
  test := 'T4 sold 20: Rice 65 -> 45'; expected := '45.000'; got := pg_temp.stock(pr); verdict := pg_temp.v(got, expected); return next;
  perform public.update_sale(s4, jsonb_build_object('notes', 'ZZ_TEST', 'payment_method', 'cash', 'amount_paid', 900, 'items', jsonb_build_array(pg_temp.item(pr, 15))));
  test := 'T4 edit 20 -> 15: 5 returned, stock 50 (not 30)'; expected := '50.000|900.00'; got := pg_temp.stock(pr) || '|' || (select grand_total from public.sales where id = s4); verdict := pg_temp.v(got, expected); return next;
  test := 'T4 history is the net change (-20 sale, +5 return)'; expected := '-20.000|5.000'; got := (select sum(quantity) filter (where movement_type = 'sale') || '|' || sum(quantity) filter (where movement_type = 'sale_return') from public.inventory_movements where product_id = pr and reference_id = (select invoice_no from public.sales where id = s4)); verdict := pg_temp.v(got, expected); return next;
  test := 'T4 sale now holds exactly 15 in allocations'; expected := '15.000'; got := (select sum(quantity)::text from public.sale_batch_allocations where sale_id = s4); verdict := pg_temp.v(got, expected); return next;

  -- TEST 5: increase 15 -> 25 takes only 10 more; too big is refused and changes nothing
  perform public.update_sale(s4, jsonb_build_object('notes', 'ZZ_TEST', 'payment_method', 'cash', 'amount_paid', 1500, 'items', jsonb_build_array(pg_temp.item(pr, 25))));
  test := 'T5 edit 15 -> 25: only 10 more taken, stock 40'; expected := '40.000'; got := pg_temp.stock(pr); verdict := pg_temp.v(got, expected); return next;
  test := 'T5 edit to 1000 refused'; expected := 'ERR P0001 INSUFFICIENT_STOCK'; got := pg_temp.try(format('select public.update_sale(%L, %L::jsonb)', s4, jsonb_build_object('notes', 'ZZ_TEST', 'payment_method', 'cash', 'amount_paid', 60000, 'items', jsonb_build_array(pg_temp.item(pr, 1000))))); verdict := pg_temp.v(got, expected); return next;
  test := 'T5 refused edit changed nothing'; expected := '40.000|1500.00|1'; got := pg_temp.stock(pr) || '|' || (select grand_total from public.sales where id = s4) || '|' || (select count(*) from public.sale_items where sale_id = s4); verdict := pg_temp.v(got, expected); return next;

  -- TEST 6: cancel restores exactly what the sale holds, once
  perform public.cancel_sale(s4, 'test');
  test := 'T6 cancel: status cancelled, stock back to 65'; expected := 'cancelled|65.000'; got := (select status from public.sales where id = s4) || '|' || pg_temp.stock(pr); verdict := pg_temp.v(got, expected); return next;
  test := 'T6 cancel again refused'; expected := 'ERR P0001 ALREADY_CANCELLED'; got := pg_temp.try(format('select public.cancel_sale(%L)', s4)); verdict := pg_temp.v(got, expected); return next;
  test := 'T6 repeated cancel did not add stock again'; expected := '65.000|0'; got := pg_temp.stock(pr) || '|' || (select count(*) from public.sale_batch_allocations where sale_id = s4); verdict := pg_temp.v(got, expected); return next;
  test := 'T6 edit a cancelled sale refused'; expected := 'ERR P0001 SALE_CANCELLED'; got := pg_temp.try(format('select public.update_sale(%L, %L::jsonb)', s4, jsonb_build_object('items', jsonb_build_array(pg_temp.item(pr, 1))))); verdict := pg_temp.v(got, expected); return next;
  test := 'T6 cancelled sale stays on record'; expected := '1|1'; got := (select count(*) from public.sales where id = s4) || '|' || (select count(*) from public.sale_items where sale_id = s4); verdict := pg_temp.v(got, expected); return next;

  -- Chain: 100 +50 purchase -30 sale, edit 30->20, cancel sale, cancel purchase
  j := public.create_purchase(jsonb_build_object('company_id', ca, 'supplier_id', sa, 'status', 'completed', 'notes', 'ZZ_TEST', 'items', jsonb_build_array(jsonb_build_object('product_id', pc, 'quantity', 50, 'unit_price', 5))));
  pur := (j->>'id')::uuid;
  test := 'Chain: purchase +50 -> 150'; expected := '150.000'; got := pg_temp.stock(pc); verdict := pg_temp.v(got, expected); return next;
  j := pg_temp.sale(ca, jsonb_build_array(pg_temp.item(pc, 30, 10)), 300); s1 := (j->>'id')::uuid;
  test := 'Chain: sale -30 -> 120'; expected := '120.000'; got := pg_temp.stock(pc); verdict := pg_temp.v(got, expected); return next;
  perform public.update_sale(s1, jsonb_build_object('notes', 'ZZ_TEST', 'payment_method', 'cash', 'amount_paid', 200, 'items', jsonb_build_array(pg_temp.item(pc, 20, 10))));
  test := 'Chain: edit sale 30 -> 20 -> 130'; expected := '130.000'; got := pg_temp.stock(pc); verdict := pg_temp.v(got, expected); return next;
  perform public.cancel_sale(s1);
  test := 'Chain: cancel sale -> 150'; expected := '150.000'; got := pg_temp.stock(pc); verdict := pg_temp.v(got, expected); return next;
  perform public.cancel_purchase(pur);
  test := 'Chain: cancel purchase -> 100'; expected := '100.000'; got := pg_temp.stock(pc); verdict := pg_temp.v(got, expected); return next;
  test := 'Chain: inventory equals sum of batches'; expected := 'true'; got := ((select quantity from public.inventory where product_id = pc) = (select sum(quantity) from public.product_batches where product_id = pc))::text; verdict := pg_temp.v(got, expected); return next;

  -- TEST 7: payments
  j := pg_temp.sale(ca, jsonb_build_array(pg_temp.item(pr, 1)), 60, jsonb_build_object('payment_method', 'upi'));
  test := 'T7 UPI stored'; expected := 'upi|paid'; got := (select payment_method || '|' || payment_status from public.sales where id = (j->>'id')::uuid); verdict := pg_temp.v(got, expected); return next;
  j := pg_temp.sale(ca, jsonb_build_array(pg_temp.item(pr, 1)), 60, jsonb_build_object('payment_method', 'card'));
  test := 'T7 card stored'; expected := 'card|paid'; got := (select payment_method || '|' || payment_status from public.sales where id = (j->>'id')::uuid); verdict := pg_temp.v(got, expected); return next;
  j := pg_temp.sale(ca, jsonb_build_array(pg_temp.item(pr, 10)), 200, jsonb_build_object('payment_method', 'credit', 'customer_id', cr));
  scr := (j->>'id')::uuid;
  test := 'T7 credit sale: partial, balance 400'; expected := 'credit|partial|400.00|ZZ_TEST Ramesh'; got := (select payment_method || '|' || payment_status || '|' || balance_due || '|' || customer_name from public.sales where id = scr); verdict := pg_temp.v(got, expected); return next;
  test := 'T7 customer owes 200 opening + 400 = 600'; expected := '600.00'; select outstanding::text into got from public.customer_outstanding(ca, array[cr]); verdict := pg_temp.v(got, expected); return next;
  j := pg_temp.sale(ca, jsonb_build_array(pg_temp.item(pr, 1)), 0, jsonb_build_object('payment_method', 'credit', 'customer_id', cr));
  test := 'T7 fully unpaid with customer = pending'; expected := 'pending|60.00'; got := (select payment_status || '|' || balance_due from public.sales where id = (j->>'id')::uuid); verdict := pg_temp.v(got, expected); return next;
  test := 'T7 credit with walk-in refused'; expected := 'ERR P0001 CUSTOMER_REQUIRED_FOR_CREDIT'; got := pg_temp.try(format('select pg_temp.sale(%L, %L::jsonb, 0, %L::jsonb)', ca, jsonb_build_array(pg_temp.item(pr, 1)), jsonb_build_object('payment_method', 'credit'))); verdict := pg_temp.v(got, expected); return next;
  test := 'T7 paid more than total refused'; expected := 'ERR P0001 PAID_EXCEEDS_TOTAL'; got := pg_temp.try(format('select pg_temp.sale(%L, %L::jsonb, 999)', ca, jsonb_build_array(pg_temp.item(pr, 1)))); verdict := pg_temp.v(got, expected); return next;
  test := 'T7 unknown payment method refused'; expected := 'ERR P0001 INVALID_PAYMENT_METHOD'; got := pg_temp.try(format('select pg_temp.sale(%L, %L::jsonb, 60, %L::jsonb)', ca, jsonb_build_array(pg_temp.item(pr, 1)), jsonb_build_object('payment_method', 'cheque'))); verdict := pg_temp.v(got, expected); return next;
  perform public.cancel_sale(scr);
  test := 'T7 cancelling the credit sale removes its 400 from the customer (600 -> 260)'; expected := '260.00'; select outstanding::text into got from public.customer_outstanding(ca, array[cr]); verdict := pg_temp.v(got, expected); return next;

  -- Walk-in details are kept without creating a customer
  j := pg_temp.sale(ca, jsonb_build_array(pg_temp.item(pr, 1)), 60, jsonb_build_object('customer_name', 'Suresh', 'customer_phone', ' 98765 43210 '));
  test := 'Walk-in name and phone saved, no customer record'; expected := 'Suresh|9876543210|true'; got := (select customer_name || '|' || customer_phone || '|' || (customer_id is null) from public.sales where id = (j->>'id')::uuid); verdict := pg_temp.v(got, expected); return next;
  j := pg_temp.sale(ca, jsonb_build_array(pg_temp.item(pr, 1)), 60);
  test := 'Walk-in with no details'; expected := 'Walk-in Customer'; got := (select customer_name from public.sales where id = (j->>'id')::uuid); verdict := pg_temp.v(got, expected); return next;
  test := 'Inactive customer refused'; expected := 'ERR P0001 CUSTOMER_INACTIVE'; got := pg_temp.try(format('select pg_temp.sale(%L, %L::jsonb, 60, %L::jsonb)', ca, jsonb_build_array(pg_temp.item(pr, 1)), jsonb_build_object('customer_id', c_old))); verdict := pg_temp.v(got, expected); return next;

  -- Batches: soonest expiry first, expired never sold, exact return
  test := 'Seed: sellable excludes expired batch'; expected := '40.000|30.000'; select total || '|' || sellable into got from public.product_sellable_stock(ca, array[psd]); verdict := pg_temp.v(got, expected); return next;
  j := pg_temp.sale(ca, jsonb_build_array(pg_temp.item(psd, 15, 100)), 1500); sfe := (j->>'id')::uuid;
  test := 'FEFO: 15 sold = SOON 10 + LATE 5; EXPIRED and NOEXP untouched'; expected := '0.000|5.000|10.000|10.000'; select (select quantity from public.product_batches where id = b_soon) || '|' || (select quantity from public.product_batches where id = b_late) || '|' || (select quantity from public.product_batches where id = b_exp) || '|' || (select quantity from public.product_batches where id = b_none) into got; verdict := pg_temp.v(got, expected); return next;
  test := 'Expired stock is not sellable (20 asked, 15 sellable, 25 in total)'; expected := 'ERR P0001 INSUFFICIENT_STOCK'; got := pg_temp.try(format('select pg_temp.sale(%L, %L::jsonb, 2000)', ca, jsonb_build_array(pg_temp.item(psd, 20, 100)))); verdict := pg_temp.v(got, expected); return next;
  test := 'Edit 15 -> 8 returns 7 to the batches it came from (LATE first)'; perform public.update_sale(sfe, jsonb_build_object('notes', 'ZZ_TEST', 'payment_method', 'cash', 'amount_paid', 800, 'items', jsonb_build_array(pg_temp.item(psd, 8, 100))));
  expected := '2.000|10.000|10.000|10.000'; select (select quantity from public.product_batches where id = b_soon) || '|' || (select quantity from public.product_batches where id = b_late) || '|' || (select quantity from public.product_batches where id = b_exp) || '|' || (select quantity from public.product_batches where id = b_none) into got; verdict := pg_temp.v(got, expected); return next;
  perform public.cancel_sale(sfe);
  test := 'Cancel returns every batch to its original quantity'; expected := '10.000|10.000|10.000|10.000|40.000'; select (select quantity from public.product_batches where id = b_soon) || '|' || (select quantity from public.product_batches where id = b_late) || '|' || (select quantity from public.product_batches where id = b_exp) || '|' || (select quantity from public.product_batches where id = b_none) || '|' || pg_temp.stock(psd) into got; verdict := pg_temp.v(got, expected); return next;

  -- Decimal quantities
  perform pg_temp.sale(ca, jsonb_build_array(pg_temp.item(po, 2.5, 120)), 300);
  perform pg_temp.sale(ca, jsonb_build_array(pg_temp.item(po, 0.75, 120)), 90);
  perform pg_temp.sale(ca, jsonb_build_array(pg_temp.item(po, 1.25, 120)), 150);
  test := 'Decimals: 10 L - 2.5 - 0.75 - 1.25 = 5.5'; expected := '5.500'; got := pg_temp.stock(po); verdict := pg_temp.v(got, expected); return next;
  test := 'More than 3 decimals refused'; expected := 'ERR P0001 INVALID_QUANTITY'; got := pg_temp.try(format('select pg_temp.sale(%L, %L::jsonb, 1)', ca, jsonb_build_array(pg_temp.item(po, 0.0001, 120)))); verdict := pg_temp.v(got, expected); return next;

  -- Money maths and snapshots: 10 x 33.33 - 3.30 = 330.00; GST 18% = 59.40; bill discount 10 -> 379.40
  j := pg_temp.sale(ca, jsonb_build_array(pg_temp.item(pt, 10, 33.33, 3.30)), 379.40, jsonb_build_object('discount', 10)); stx := (j->>'id')::uuid;
  test := 'Totals: subtotal|tax|grand'; expected := '330.00|59.40|379.40'; got := (select subtotal || '|' || tax || '|' || grand_total from public.sales where id = stx); verdict := pg_temp.v(got, expected); return next;
  reset role;
  update public.products set product_name = 'ZZ_TEST Tax18 RENAMED', tax_rate = 28 where id = pt;
  perform pg_temp.login(ua);
  test := 'Old invoice keeps the product name it was sold under'; expected := 'ZZ_TEST Tax18'; got := (select product_name_snapshot from public.sale_items where sale_id = stx); verdict := pg_temp.v(got, expected); return next;
  perform public.update_sale(stx, jsonb_build_object('notes', 'ZZ_TEST', 'payment_method', 'cash', 'amount_paid', 379.40, 'discount', 10, 'items', jsonb_build_array(pg_temp.item(pt, 10, 33.33, 3.30))));
  test := 'Editing keeps the GST rate the line was sold at (18, not the new 28)'; expected := '18.00|59.40'; got := (select tax_rate || '|' || tax from public.sale_items where sale_id = stx); verdict := pg_temp.v(got, expected); return next;
  j := pg_temp.sale(ca, jsonb_build_array(pg_temp.item(pt, 1, 100)), 128);
  test := 'A new sale uses the product''s current GST (28%)'; expected := '28.00|128.00'; got := (select tax_rate || '|' || line_total from public.sale_items where sale_id = (j->>'id')::uuid); verdict := pg_temp.v(got, expected); return next;

  -- Validation / foreign ids
  test := 'No items refused'; expected := 'ERR P0001 NO_ITEMS'; got := pg_temp.try(format('select pg_temp.sale(%L, %L::jsonb, 0)', ca, jsonb_build_array())); verdict := pg_temp.v(got, expected); return next;
  test := 'Quantity 0 refused'; expected := 'ERR P0001 INVALID_QUANTITY'; got := pg_temp.try(format('select pg_temp.sale(%L, %L::jsonb, 0)', ca, jsonb_build_array(pg_temp.item(pr, 0)))); verdict := pg_temp.v(got, expected); return next;
  test := 'Negative price refused'; expected := 'ERR P0001 INVALID_AMOUNT'; got := pg_temp.try(format('select pg_temp.sale(%L, %L::jsonb, 0)', ca, jsonb_build_array(pg_temp.item(pr, 1, -5)))); verdict := pg_temp.v(got, expected); return next;
  test := 'Using Shop B''s product refused'; expected := 'ERR P0001 PRODUCT_NOT_FOUND'; got := pg_temp.try(format('select pg_temp.sale(%L, %L::jsonb, 60)', ca, jsonb_build_array(pg_temp.item(pbr, 1)))); verdict := pg_temp.v(got, expected); return next;
  test := 'Using Shop B''s customer refused'; expected := 'ERR P0001 CUSTOMER_NOT_FOUND'; got := pg_temp.try(format('select pg_temp.sale(%L, %L::jsonb, 60, %L::jsonb)', ca, jsonb_build_array(pg_temp.item(pr, 1)), jsonb_build_object('customer_id', ck))); verdict := pg_temp.v(got, expected); return next;

  -- Direct table writes are impossible
  test := 'Direct INSERT into sales blocked'; expected := 'ERR 42501%'; got := pg_temp.try(format('insert into public.sales(company_id, invoice_no) values (%L, ''INV-999999'')', ca)); verdict := pg_temp.v(got, expected); return next;
  test := 'Direct UPDATE of sales blocked'; expected := 'ERR 42501%'; got := pg_temp.try(format('update public.sales set status = ''completed'' where id = %L', s4)); verdict := pg_temp.v(got, expected); return next;
  test := 'Direct DELETE of sales blocked'; expected := 'ERR 42501%'; got := pg_temp.try(format('delete from public.sales where id = %L', s2)); verdict := pg_temp.v(got, expected); return next;
  test := 'Direct write to sale_items blocked'; expected := 'ERR 42501%'; got := pg_temp.try(format('update public.sale_items set quantity = 1 where sale_id = %L', s2)); verdict := pg_temp.v(got, expected); return next;
  test := 'Invoice counter not readable'; expected := 'ERR 42501%'; got := pg_temp.try('select * from public.sale_counters'); verdict := pg_temp.v(got, expected); return next;
  test := 'Internal stock helpers not callable'; expected := 'ERR 42501%'; got := pg_temp.try(format('select public.sale_stock_take(%L, %L, %L, 1, ''x'')', ca, s2, pr)); verdict := pg_temp.v(got, expected); return next;

  -- Dashboard counters move by exactly the completed sales made today
  st1 := public.sale_stats(ca, today);
  test := 'sale_stats: today count/pending are consistent with the sales table'; expected := 'true|true';
  got := (((st1->>'today_count')::int - (st0->>'today_count')::int) = (select count(*) from public.sales where company_id = ca and status = 'completed' and sale_date = today and notes like 'ZZ\_TEST%'))::text
      || '|' || (((st1->>'pending_total')::numeric - (st0->>'pending_total')::numeric) = (select coalesce(sum(balance_due), 0) from public.sales where company_id = ca and status = 'completed' and notes like 'ZZ\_TEST%'))::text;
  verdict := pg_temp.v(got, expected); return next;

  ---------------- Shop B (owner) ----------------
  reset role; perform pg_temp.login(ub);
  test := 'B sees none of A''s sales / items / allocations'; expected := '0|0|0'; got := (select count(*) from public.sales where company_id = ca) || '|' || (select count(*) from public.sale_items where company_id = ca) || '|' || (select count(*) from public.sale_batch_allocations where company_id = ca); verdict := pg_temp.v(got, expected); return next;
  test := 'B sees none of A''s stock or customers'; expected := '0|0'; got := (select count(*) from public.inventory where company_id = ca) || '|' || (select count(*) from public.customers where company_id = ca); verdict := pg_temp.v(got, expected); return next;
  test := 'B customer_outstanding(A) is empty'; expected := '0'; select count(*)::text into got from public.customer_outstanding(ca); verdict := pg_temp.v(got, expected); return next;
  test := 'B EDIT A''s sale refused'; expected := 'ERR P0001 NOT_ALLOWED'; got := pg_temp.try(format('select public.update_sale(%L, %L::jsonb)', s2, jsonb_build_object('items', jsonb_build_array(pg_temp.item(pbr, 1))))); verdict := pg_temp.v(got, expected); return next;
  test := 'B CANCEL A''s sale refused'; expected := 'ERR P0001 NOT_ALLOWED'; got := pg_temp.try(format('select public.cancel_sale(%L)', s2)); verdict := pg_temp.v(got, expected); return next;
  test := 'B creates a sale inside A (company_id = A)'; expected := 'ERR P0001 NOT_ALLOWED'; got := pg_temp.try(format('select pg_temp.sale(%L, %L::jsonb, 60)', ca, jsonb_build_array(pg_temp.item(pr, 1)))); verdict := pg_temp.v(got, expected); return next;
  test := 'B sells A''s product from its own shop'; expected := 'ERR P0001 PRODUCT_NOT_FOUND'; got := pg_temp.try(format('select pg_temp.sale(%L, %L::jsonb, 60)', cb, jsonb_build_array(pg_temp.item(pr, 1)))); verdict := pg_temp.v(got, expected); return next;
  j := pg_temp.sale(cb, jsonb_build_array(pg_temp.item(pbr, 10)), 600); sb1 := (j->>'id')::uuid;
  test := 'B sale: own stock 50 -> 40, A''s Rice untouched'; expected := '40.000'; got := pg_temp.stock(pbr); verdict := pg_temp.v(got, expected); return next;
  test := 'B invoice numbering is its own sequence'; expected := '%-' || lpad((coalesce(ctr_sb, 0) + 1)::text, 6, '0'); got := j->>'invoice_no'; verdict := pg_temp.v(got, expected); return next;
  test := 'B sees only its own sale'; expected := '1'; got := (select count(*) from public.sales where notes like 'ZZ\_TEST%')::text; verdict := pg_temp.v(got, expected); return next;

  ---------------- Shop A again ----------------
  reset role; perform pg_temp.login(ua);
  test := 'A sees none of B''s sales; A''s own Rice is unaffected by B (60)'; expected := '0|60.000'; got := (select count(*) from public.sales where company_id = cb) || '|' || pg_temp.stock(pr); verdict := pg_temp.v(got, expected); return next;
  test := 'A CANCEL B''s sale refused'; expected := 'ERR P0001 NOT_ALLOWED'; got := pg_temp.try(format('select public.cancel_sale(%L)', sb1)); verdict := pg_temp.v(got, expected); return next;
  test := 'A EDIT B''s sale refused'; expected := 'ERR P0001 NOT_ALLOWED'; got := pg_temp.try(format('select public.update_sale(%L, %L::jsonb)', sb1, jsonb_build_object('items', jsonb_build_array(pg_temp.item(pr, 1))))); verdict := pg_temp.v(got, expected); return next;

  ---------------- Shop B demoted to cashier (reverted below) ----------------
  reset role;
  update public.company_members set role = 'cashier' where user_id = ub and company_id = cb;
  perform pg_temp.login(ub);
  test := 'Cashier can read sales'; expected := '1'; got := (select count(*) from public.sales where notes like 'ZZ\_TEST%')::text; verdict := pg_temp.v(got, expected); return next;
  j := pg_temp.sale(cb, jsonb_build_array(pg_temp.item(pbr, 5)), 300);
  test := 'Cashier CAN create a sale; stock 40 -> 35'; expected := '35.000'; got := pg_temp.stock(pbr); verdict := pg_temp.v(got, expected); return next;
  test := 'Cashier cannot edit'; expected := 'ERR P0001 NOT_ALLOWED'; got := pg_temp.try(format('select public.update_sale(%L, %L::jsonb)', sb1, jsonb_build_object('items', jsonb_build_array(pg_temp.item(pbr, 1))))); verdict := pg_temp.v(got, expected); return next;
  test := 'Cashier cannot cancel'; expected := 'ERR P0001 NOT_ALLOWED'; got := pg_temp.try(format('select public.cancel_sale(%L)', sb1)); verdict := pg_temp.v(got, expected); return next;
  test := 'Cashier cannot read stock allocations'; expected := '0'; got := (select count(*) from public.sale_batch_allocations)::text; verdict := pg_temp.v(got, expected); return next;

  ---------------- Not logged in ----------------
  reset role; set local role anon;
  test := 'Anonymous cannot read sales'; expected := 'ERR 42501%'; got := pg_temp.try('select 1 from public.sales'); verdict := pg_temp.v(got, expected); return next;
  test := 'Anonymous cannot call create_sale'; expected := 'ERR 42501%'; got := pg_temp.try(format('select public.create_sale(%L::jsonb)', jsonb_build_object('company_id', ca))); verdict := pg_temp.v(got, expected); return next;

  ---------------- Clean up everything this test created ----------------
  reset role;
  update public.company_members set role = role_b where user_id = ub and company_id = cb;
  delete from public.audit_logs where (record_type = 'sale' and record_id in (select id::text from public.sales where notes like 'ZZ\_TEST%'))
     or (record_type = 'purchase' and record_id in (select id::text from public.purchases where notes like 'ZZ\_TEST%'));
  delete from public.sales where notes like 'ZZ\_TEST%';
  delete from public.purchases where notes like 'ZZ\_TEST%';
  delete from public.inventory_movements where product_id in (select id from public.products where product_name like 'ZZ\_TEST%');
  delete from public.products where product_name like 'ZZ\_TEST%';
  delete from public.categories where name like 'ZZ\_TEST%';
  delete from public.customers where customer_name like 'ZZ\_TEST%';
  delete from public.suppliers where supplier_name like 'ZZ\_TEST%';
  if ctr_sa is null then delete from public.sale_counters where company_id = ca; else update public.sale_counters set last_no = ctr_sa where company_id = ca; end if;
  if ctr_sb is null then delete from public.sale_counters where company_id = cb; else update public.sale_counters set last_no = ctr_sb where company_id = cb; end if;
  if ctr_pa is null then delete from public.purchase_counters where company_id = ca; else update public.purchase_counters set last_no = ctr_pa where company_id = ca; end if;
  if ctr_pb is null then delete from public.purchase_counters where company_id = cb; else update public.purchase_counters set last_no = ctr_pb where company_id = cb; end if;
  test := 'Cleanup: no test data left, Shop B role restored'; expected := '0|0|0|0|' || role_b;
  got := (select count(*) from public.sales where notes like 'ZZ\_TEST%') || '|' || (select count(*) from public.products where product_name like 'ZZ\_TEST%') || '|' || (select count(*) from public.customers where customer_name like 'ZZ\_TEST%') || '|' || (select count(*) from public.suppliers where supplier_name like 'ZZ\_TEST%') || '|' || (select role from public.company_members where user_id = ub and company_id = cb);
  verdict := pg_temp.v(got, expected); return next;
  return;
end $$;

select * from pg_temp.phase5_test();
