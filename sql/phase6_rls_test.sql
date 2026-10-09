-- Agro POS — Phase 6 payments + expenses test (functional + shop isolation). Run in the Supabase SQL Editor.
--
-- BEFORE RUNNING: replace the two emails below with the logins of two DIFFERENT shops (Shop A and Shop B), then Run.
-- You get one table of PASS/FAIL rows. The test creates 'ZZ_TEST ...' customers/suppliers/products/sales/purchases/payments/
-- expenses, checks balances, the payment ledger, void/cancel rules, roles and cross-shop attacks, then DELETES everything it
-- created and restores the invoice/purchase/receipt counters, so your next real numbers are unaffected. One transaction: any
-- unexpected error rolls the whole thing back. Your real data is never touched.

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

create or replace function pg_temp.item(pid uuid, qty numeric, price numeric default 50) returns jsonb language sql as
$$ select jsonb_build_object('product_id', pid, 'quantity', qty, 'unit_price', price, 'discount', 0) $$;

create or replace function pg_temp.sale(cid uuid, items jsonb, paid numeric, extra jsonb default '{}'::jsonb) returns jsonb language sql as
$$ select public.create_sale(jsonb_build_object('company_id', cid, 'notes', 'ZZ_TEST', 'payment_method', 'cash', 'amount_paid', paid, 'items', items) || extra) $$;

-- receive (in) / pay (out): allocations = jsonb array of {doc_id, amount}
create or replace function pg_temp.rp(cid uuid, dir text, party uuid, allocs jsonb, extra jsonb default '{}'::jsonb) returns jsonb language sql as
$$ select public.record_payments(jsonb_build_object('company_id', cid, 'direction', dir, 'party_id', party, 'payment_method', 'cash', 'allocations', allocs) || extra) $$;

create or replace function pg_temp.al(doc uuid, amt numeric) returns jsonb language sql as $$ select jsonb_build_object('doc_id', doc, 'amount', amt) $$;

-- the ledger must always equal the invoice: sum(completed payments) = amount_paid
create or replace function pg_temp.ledger_ok() returns text language sql as $$
  select ((select count(*) from public.sales s where s.notes like 'ZZ\_TEST%' and s.amount_paid <> coalesce((select sum(amount) from public.payments where sale_id = s.id and status = 'completed'), 0))
        + (select count(*) from public.purchases u where u.notes like 'ZZ\_TEST%' and u.completed_at is not null and u.amount_paid <> coalesce((select sum(amount) from public.payments where purchase_id = u.id and status = 'completed'), 0)))::text $$;

create or replace function pg_temp.phase6_test() returns table(test text, expected text, got text, verdict text)
language plpgsql as $$
declare
  email_a text := 'CHANGE_ME_shop_a@example.com';   -- <<< Shop A login email
  email_b text := 'CHANGE_ME_shop_b@example.com';   -- <<< Shop B login email
  ua uuid; ub uuid; ca uuid; cb uuid; role_b text; today date := public.today_ist();
  cat_a uuid; cat_b uuid; pr uuid; pbr uuid; cr uuid; cr2 uuid; ck uuid; sa uuid; sbp uuid; ec_a uuid; ec_b uuid; ec_old uuid;
  c_sin int; c_sout int; c_pin int; c_pout int; c_sin_b int; c_pin_b int; c_ppin int; c_ppout int; c_ppin_b int;
  st0 jsonb; st1 jsonb; j jsonb; s1 uuid; s2 uuid; s3 uuid; s4 uuid; s5 uuid; s6 uuid; s7 uuid; s8 uuid; sb1 uuid; pu1 uuid; pu2 uuid; pu3 uuid; pu4 uuid; pay_id uuid; init_id uuid;
  e1 uuid; e2 uuid; e3 uuid; r1 text; r2 text; n0 int; x text; newco uuid; ctr_new int; cnt_b int;
begin
  select id into ua from auth.users where lower(email) = lower(email_a);
  select id into ub from auth.users where lower(email) = lower(email_b);
  if ua is null or ub is null then raise exception 'Could not find one of the two emails in auth.users. Edit email_a / email_b.'; end if;
  select company_id into ca from public.company_members where user_id = ua limit 1;
  select company_id, role into cb, role_b from public.company_members where user_id = ub limit 1;
  if ca is null or cb is null then raise exception 'One of the accounts has no shop yet (log in once first).'; end if;
  if ca = cb then raise exception 'Both emails belong to the same shop. Use two different shops.'; end if;
  select id into ec_a from public.expense_categories where company_id = ca and lower(name) = 'transport';
  select id into ec_b from public.expense_categories where company_id = cb and lower(name) = 'transport';
  if ec_a is null or ec_b is null then raise exception 'Default expense categories are missing. Run phase6_payments_expenses.sql first.'; end if;

  select last_no into c_sin from public.sale_counters where company_id = ca;     select last_no into c_sin_b from public.sale_counters where company_id = cb;
  select last_no into c_pin from public.purchase_counters where company_id = ca; select last_no into c_ppin_b from public.purchase_counters where company_id = cb;
  select last_no into c_ppin from public.payment_counters where company_id = ca and direction = 'in';  select last_no into c_ppout from public.payment_counters where company_id = ca and direction = 'out';
  select last_no into c_pin_b from public.payment_counters where company_id = cb and direction = 'in';

  -- leftovers from an interrupted earlier run
  delete from public.audit_logs where company_id in (ca, cb) and created_at >= now();
  delete from public.sales where notes like 'ZZ\_TEST%';
  delete from public.purchases where notes like 'ZZ\_TEST%';
  delete from public.expenses where description like 'ZZ\_TEST%';
  delete from public.expense_categories where name like 'ZZ\_TEST%';
  delete from public.inventory_movements where product_id in (select id from public.products where product_name like 'ZZ\_TEST%');
  delete from public.products where product_name like 'ZZ\_TEST%';
  delete from public.categories where name like 'ZZ\_TEST%';
  delete from public.customers where customer_name like 'ZZ\_TEST%';
  delete from public.suppliers where supplier_name like 'ZZ\_TEST%';
  delete from public.companies where name like 'ZZ\_TEST%';

  -- seed as table owner (bypasses RLS)
  insert into public.categories(company_id, name) values (ca, 'ZZ_TEST Cat') returning id into cat_a;
  insert into public.categories(company_id, name) values (cb, 'ZZ_TEST Cat') returning id into cat_b;
  insert into public.products(company_id, category_id, product_name, unit, selling_price) values (ca, cat_a, 'ZZ_TEST Rice', 'Kg', 50) returning id into pr;
  insert into public.products(company_id, category_id, product_name, unit, selling_price) values (cb, cat_b, 'ZZ_TEST Rice B', 'Kg', 50) returning id into pbr;
  insert into public.inventory(company_id, product_id, quantity) values (ca, pr, 10000), (cb, pbr, 10000);
  insert into public.product_batches(company_id, product_id, batch_number, quantity) values (ca, pr, 'OPENING', 10000), (cb, pbr, 'OPENING', 10000);
  insert into public.customers(company_id, customer_name, phone, opening_balance, balance_type) values (ca, 'ZZ_TEST Ramesh', '9876543210', 200, 'debit') returning id into cr;
  insert into public.customers(company_id, customer_name, phone) values (ca, 'ZZ_TEST Other', '9876543211') returning id into cr2;
  insert into public.customers(company_id, customer_name, phone) values (cb, 'ZZ_TEST Kumar', '9123456780') returning id into ck;
  insert into public.suppliers(company_id, supplier_name, phone) values (ca, 'ZZ_TEST ABC Agro', '9876500000') returning id into sa;
  insert into public.suppliers(company_id, supplier_name, phone) values (cb, 'ZZ_TEST XYZ Agro', '9123400000') returning id into sbp;

  ---------------- Shop A (owner) ----------------
  perform pg_temp.login(ua);
  st0 := public.finance_stats(ca, today);

  -- TEST 1: sale of 5,000 fully paid
  j := pg_temp.sale(ca, jsonb_build_array(pg_temp.item(pr, 100)), 5000); s1 := (j->>'id')::uuid;
  test := 'T1 sale 5,000 paid in full = PAID'; expected := '5000.00|paid|0.00'; got := (select grand_total || '|' || payment_status || '|' || balance_due from public.sales where id = s1); verdict := pg_temp.v(got, expected); return next;
  test := 'T1 payment appears in the ledger (at billing, cash, received, walk-in)'; expected := '1|initial|5000.00|cash|in|Walk-in Customer'; got := (select count(*) || '|' || min(kind) || '|' || min(amount) || '|' || min(payment_method) || '|' || min(direction) || '|' || min(party_name) from public.payments where sale_id = s1); verdict := pg_temp.v(got, expected); return next;

  -- TEST 2: sale of 10,000 with 4,000 paid
  j := pg_temp.sale(ca, jsonb_build_array(pg_temp.item(pr, 200)), 4000, jsonb_build_object('customer_id', cr)); s2 := (j->>'id')::uuid;
  test := 'T2 sale 10,000 with 4,000 paid: outstanding 6,000, partial'; expected := '6000.00|partial'; got := (select balance_due || '|' || payment_status from public.sales where id = s2); verdict := pg_temp.v(got, expected); return next;
  test := 'T2 customer owes 200 opening + 6,000 = 6,200'; expected := '6200.00'; select outstanding::text into got from public.customer_outstanding(ca, array[cr]); verdict := pg_temp.v(got, expected); return next;

  -- TEST 3: customer pays the remaining 6,000 later
  j := pg_temp.rp(ca, 'in', cr, jsonb_build_array(pg_temp.al(s2, 6000)), jsonb_build_object('payment_method', 'upi', 'reference_number', 'UPI123', 'notes', 'ZZ_TEST'));
  r1 := j->>'receipt_no';
  test := 'T3 receipt number issued'; expected := 'RCT-' || lpad((coalesce(c_ppin, 0) + 1)::text, 6, '0'); got := r1; verdict := pg_temp.v(got, expected); return next;
  test := 'T3 outstanding 0, status PAID, 10,000 paid'; expected := '0.00|paid|10000.00'; got := (select balance_due || '|' || payment_status || '|' || amount_paid from public.sales where id = s2); verdict := pg_temp.v(got, expected); return next;
  test := 'T3 history keeps both payments (4,000 at billing + 6,000 later)'; expected := '2|10000.00|4000.00,6000.00'; got := (select count(*) || '|' || sum(amount) || '|' || string_agg(amount::text, ',' order by amount) from public.payments where sale_id = s2 and status = 'completed'); verdict := pg_temp.v(got, expected); return next;
  test := 'T7 payment row: amount, method, reference, party, invoice, date, user'; expected := '6000.00|upi|UPI123|ZZ_TEST Ramesh|true|true|true';
  select amount || '|' || payment_method || '|' || reference_number || '|' || party_name || '|' || (doc_no = (select invoice_no from public.sales where id = s2)) || '|' || (payment_date = today) || '|' || (created_by = ua) into got from public.payments where sale_id = s2 and kind = 'payment'; verdict := pg_temp.v(got, expected); return next;
  test := 'T3 customer outstanding back to the 200 opening balance'; expected := '200.00'; select outstanding::text into got from public.customer_outstanding(ca, array[cr]); verdict := pg_temp.v(got, expected); return next;
  test := 'Ledger equals invoices (sum of payments = amount_paid)'; expected := '0'; got := pg_temp.ledger_ok(); verdict := pg_temp.v(got, expected); return next;
  select id into pay_id from public.payments where sale_id = s2 and kind = 'payment'; select id into init_id from public.payments where sale_id = s2 and kind = 'initial';

  -- payment rules
  test := 'Paying a settled invoice again is refused'; expected := 'ERR P0001 PAYMENT_EXCEEDS_DUE'; got := pg_temp.try(format('select pg_temp.rp(%L, ''in'', %L, %L::jsonb)', ca, cr, jsonb_build_array(pg_temp.al(s2, 1)))); verdict := pg_temp.v(got, expected); return next;
  j := pg_temp.sale(ca, jsonb_build_array(pg_temp.item(pr, 6)), 0, jsonb_build_object('customer_id', cr, 'payment_method', 'credit')); s3 := (j->>'id')::uuid;
  j := pg_temp.sale(ca, jsonb_build_array(pg_temp.item(pr, 10)), 0, jsonb_build_object('customer_id', cr, 'payment_method', 'credit')); s4 := (j->>'id')::uuid;
  j := pg_temp.sale(ca, jsonb_build_array(pg_temp.item(pr, 20)), 0, jsonb_build_object('customer_id', cr, 'payment_method', 'credit')); s5 := (j->>'id')::uuid;
  j := pg_temp.sale(ca, jsonb_build_array(pg_temp.item(pr, 2)), 0, jsonb_build_object('customer_id', cr2, 'payment_method', 'credit')); s6 := (j->>'id')::uuid;
  j := pg_temp.rp(ca, 'in', cr, jsonb_build_array(pg_temp.al(s3, 300), pg_temp.al(s4, 500)), jsonb_build_object('notes', 'ZZ_TEST')); r2 := j->>'receipt_no';
  test := 'One receipt pays two invoices: both settled'; expected := 'paid|paid'; got := (select payment_status from public.sales where id = s3) || '|' || (select payment_status from public.sales where id = s4); verdict := pg_temp.v(got, expected); return next;
  test := 'Both ledger rows share one receipt number (a new one)'; expected := '2|true'; got := (select count(*) || '|' || (min(receipt_no) = r2 and r2 <> r1) from public.payments where sale_id in (s3, s4) and kind = 'payment'); verdict := pg_temp.v(got, expected); return next;
  perform pg_temp.rp(ca, 'in', cr, jsonb_build_array(pg_temp.al(s5, 400)));
  test := 'Part payment on 1,000: status partial, 600 still due'; expected := 'partial|600.00'; got := (select payment_status || '|' || balance_due from public.sales where id = s5); verdict := pg_temp.v(got, expected); return next;
  test := 'Zero amount refused'; expected := 'ERR P0001 INVALID_AMOUNT'; got := pg_temp.try(format('select pg_temp.rp(%L, ''in'', %L, %L::jsonb)', ca, cr, jsonb_build_array(pg_temp.al(s5, 0)))); verdict := pg_temp.v(got, expected); return next;
  test := 'Negative amount refused'; expected := 'ERR P0001 INVALID_AMOUNT'; got := pg_temp.try(format('select pg_temp.rp(%L, ''in'', %L, %L::jsonb)', ca, cr, jsonb_build_array(pg_temp.al(s5, -50)))); verdict := pg_temp.v(got, expected); return next;
  test := 'More than 2 decimals refused'; expected := 'ERR P0001 INVALID_AMOUNT'; got := pg_temp.try(format('select pg_temp.rp(%L, ''in'', %L, %L::jsonb)', ca, cr, jsonb_build_array(pg_temp.al(s5, 10.005)))); verdict := pg_temp.v(got, expected); return next;
  test := 'More than is due refused'; expected := 'ERR P0001 PAYMENT_EXCEEDS_DUE'; got := pg_temp.try(format('select pg_temp.rp(%L, ''in'', %L, %L::jsonb)', ca, cr, jsonb_build_array(pg_temp.al(s5, 600.01)))); verdict := pg_temp.v(got, expected); return next;
  test := 'Same invoice twice in one receipt refused'; expected := 'ERR P0001 DUPLICATE_ALLOCATION'; got := pg_temp.try(format('select pg_temp.rp(%L, ''in'', %L, %L::jsonb)', ca, cr, jsonb_build_array(pg_temp.al(s5, 10), pg_temp.al(s5, 10)))); verdict := pg_temp.v(got, expected); return next;
  test := 'No allocations refused'; expected := 'ERR P0001 NO_ALLOCATIONS'; got := pg_temp.try(format('select pg_temp.rp(%L, ''in'', %L, %L::jsonb)', ca, cr, jsonb_build_array())); verdict := pg_temp.v(got, expected); return next;
  test := 'Unknown customer refused'; expected := 'ERR P0001 PARTY_NOT_FOUND'; got := pg_temp.try(format('select pg_temp.rp(%L, ''in'', %L, %L::jsonb)', ca, gen_random_uuid(), jsonb_build_array(pg_temp.al(s5, 10)))); verdict := pg_temp.v(got, expected); return next;
  test := 'Another customer''s invoice refused'; expected := 'ERR P0001 DOCUMENT_NOT_FOUND'; got := pg_temp.try(format('select pg_temp.rp(%L, ''in'', %L, %L::jsonb)', ca, cr, jsonb_build_array(pg_temp.al(s6, 10)))); verdict := pg_temp.v(got, expected); return next;
  test := 'Unknown payment method refused'; expected := 'ERR P0001 INVALID_PAYMENT_METHOD'; got := pg_temp.try(format('select pg_temp.rp(%L, ''in'', %L, %L::jsonb, %L::jsonb)', ca, cr, jsonb_build_array(pg_temp.al(s5, 10)), jsonb_build_object('payment_method', 'cheque'))); verdict := pg_temp.v(got, expected); return next;
  perform public.cancel_sale(s6);
  test := 'Paying a cancelled invoice refused'; expected := 'ERR P0001 DOCUMENT_CANCELLED'; got := pg_temp.try(format('select pg_temp.rp(%L, ''in'', %L, %L::jsonb)', ca, cr2, jsonb_build_array(pg_temp.al(s6, 10)))); verdict := pg_temp.v(got, expected); return next;
  select count(*) into n0 from public.payments where sale_id = s5;
  test := 'All-or-nothing: a bad second line saves nothing'; expected := 'ERR P0001 DOCUMENT_NOT_FOUND'; got := pg_temp.try(format('select pg_temp.rp(%L, ''in'', %L, %L::jsonb)', ca, cr, jsonb_build_array(pg_temp.al(s5, 100), pg_temp.al(gen_random_uuid(), 50)))); verdict := pg_temp.v(got, expected); return next;
  test := 'All-or-nothing: invoice and ledger unchanged (600 due, same rows)'; expected := '600.00|true'; got := (select balance_due from public.sales where id = s5) || '|' || ((select count(*) from public.payments where sale_id = s5) = n0); verdict := pg_temp.v(got, expected); return next;

  -- void a later payment, then pay again
  test := 'Voiding the at-billing amount is refused'; expected := 'ERR P0001 CANNOT_VOID_INITIAL'; got := pg_temp.try(format('select public.void_payment(%L)', init_id)); verdict := pg_temp.v(got, expected); return next;
  perform public.void_payment(pay_id, 'wrong entry');
  test := 'Void: invoice reopens (6,000 due, partial, 4,000 paid)'; expected := '6000.00|partial|4000.00'; got := (select balance_due || '|' || payment_status || '|' || amount_paid from public.sales where id = s2); verdict := pg_temp.v(got, expected); return next;
  test := 'Void keeps the row, marked cancelled with who/when'; expected := 'cancelled|true|true|wrong entry'; got := (select status || '|' || (cancelled_by = ua) || '|' || (cancelled_at is not null) || '|' || cancel_reason from public.payments where id = pay_id); verdict := pg_temp.v(got, expected); return next;
  test := 'Voiding twice refused'; expected := 'ERR P0001 ALREADY_CANCELLED'; got := pg_temp.try(format('select public.void_payment(%L)', pay_id)); verdict := pg_temp.v(got, expected); return next;
  test := 'Customer owes 200 + 6,000 + 600 = 6,800 again'; expected := '6800.00'; select outstanding::text into got from public.customer_outstanding(ca, array[cr]); verdict := pg_temp.v(got, expected); return next;
  perform pg_temp.rp(ca, 'in', cr, jsonb_build_array(pg_temp.al(s2, 6000)));
  test := 'Paid again after void: settled, history shows the voided + the new payment'; expected := 'paid|3|1'; got := (select payment_status from public.sales where id = s2) || '|' || (select count(*) from public.payments where sale_id = s2) || '|' || (select count(*) from public.payments where sale_id = s2 and status = 'cancelled'); verdict := pg_temp.v(got, expected); return next;
  test := 'Ledger equals invoices after void/re-pay'; expected := '0'; got := pg_temp.ledger_ok(); verdict := pg_temp.v(got, expected); return next;

  -- editing an invoice that has later payments
  test := 'Lowering amount received below later payments is refused'; expected := 'ERR P0001 PAYMENTS_EXIST';
  got := pg_temp.try(format('select public.update_sale(%L, %L::jsonb)', s2, jsonb_build_object('notes', 'ZZ_TEST', 'customer_id', cr, 'payment_method', 'cash', 'amount_paid', 5000, 'items', jsonb_build_array(pg_temp.item(pr, 200))))); verdict := pg_temp.v(got, expected); return next;
  test := 'Shrinking the bill below what was paid is refused'; expected := 'ERR P0001 PAID_EXCEEDS_TOTAL';
  got := pg_temp.try(format('select public.update_sale(%L, %L::jsonb)', s2, jsonb_build_object('notes', 'ZZ_TEST', 'customer_id', cr, 'payment_method', 'cash', 'amount_paid', 10000, 'items', jsonb_build_array(pg_temp.item(pr, 100))))); verdict := pg_temp.v(got, expected); return next;
  test := 'Failed edits changed nothing'; expected := '10000.00|10000.00|0.00'; got := (select grand_total || '|' || amount_paid || '|' || balance_due from public.sales where id = s2); verdict := pg_temp.v(got, expected); return next;
  j := pg_temp.sale(ca, jsonb_build_array(pg_temp.item(pr, 100)), 1000, jsonb_build_object('customer_id', cr)); s7 := (j->>'id')::uuid;
  perform public.update_sale(s7, jsonb_build_object('notes', 'ZZ_TEST', 'customer_id', cr, 'payment_method', 'cash', 'amount_paid', 2000, 'items', jsonb_build_array(pg_temp.item(pr, 100))));
  test := 'Editing amount received updates the at-billing ledger row (one row, 2,000)'; expected := '1|2000.00'; got := (select count(*) || '|' || sum(amount) from public.payments where sale_id = s7); verdict := pg_temp.v(got, expected); return next;
  perform public.update_sale(s7, jsonb_build_object('notes', 'ZZ_TEST', 'customer_id', cr, 'payment_method', 'cash', 'amount_paid', 0, 'items', jsonb_build_array(pg_temp.item(pr, 100))));
  test := 'Amount received set to 0: ledger row removed'; expected := '0'; got := (select count(*) from public.payments where sale_id = s7)::text; verdict := pg_temp.v(got, expected); return next;

  -- Purchases and supplier payments
  j := public.create_purchase(jsonb_build_object('company_id', ca, 'supplier_id', sa, 'status', 'completed', 'notes', 'ZZ_TEST', 'invoice_number', 'ZZ-INV-1', 'amount_paid', 500,
        'items', jsonb_build_array(jsonb_build_object('product_id', pr, 'quantity', 100, 'unit_price', 15)))); pu1 := (j->>'id')::uuid;
  test := 'Purchase 1,500 with 500 paid: ledger row out, 500'; expected := '1|initial|500.00|out|ZZ-INV-1'; got := (select count(*) || '|' || min(kind) || '|' || min(amount) || '|' || min(direction) || '|' || min(reference_number) from public.payments where purchase_id = pu1); verdict := pg_temp.v(got, expected); return next;
  test := 'Supplier owes 1,000 so far'; expected := '1000.00'; select outstanding::text into got from public.supplier_outstanding(ca, array[sa]); verdict := pg_temp.v(got, expected); return next;
  j := pg_temp.rp(ca, 'out', sa, jsonb_build_array(pg_temp.al(pu1, 1000)), jsonb_build_object('payment_method', 'bank_transfer', 'reference_number', 'NEFT-9'));
  test := 'Supplier paid 1,000: purchase paid, receipt PAY-'; expected := 'paid|0.00|PAY-%'; got := (select payment_status || '|' || balance_due from public.purchases where id = pu1) || '|' || (j->>'receipt_no'); verdict := pg_temp.v(got, expected); return next;
  test := 'Supplier outstanding now 0'; expected := '0.00'; select outstanding::text into got from public.supplier_outstanding(ca, array[sa]); verdict := pg_temp.v(got, expected); return next;
  j := public.create_purchase(jsonb_build_object('company_id', ca, 'supplier_id', sa, 'status', 'draft', 'notes', 'ZZ_TEST', 'amount_paid', 300,
        'items', jsonb_build_array(jsonb_build_object('product_id', pr, 'quantity', 40, 'unit_price', 10)))); pu2 := (j->>'id')::uuid;
  test := 'Draft purchase with a planned payment makes no ledger row'; expected := '0'; got := (select count(*) from public.payments where purchase_id = pu2)::text; verdict := pg_temp.v(got, expected); return next;
  test := 'Paying a draft purchase refused'; expected := 'ERR P0001 DOCUMENT_NOT_COMPLETED'; got := pg_temp.try(format('select pg_temp.rp(%L, ''out'', %L, %L::jsonb)', ca, sa, jsonb_build_array(pg_temp.al(pu2, 10)))); verdict := pg_temp.v(got, expected); return next;
  perform public.update_purchase(pu2, jsonb_build_object('supplier_id', sa, 'status', 'completed', 'notes', 'ZZ_TEST', 'amount_paid', 300, 'items', jsonb_build_array(jsonb_build_object('product_id', pr, 'quantity', 40, 'unit_price', 10))));
  test := 'Completing the draft creates the ledger row (300)'; expected := '1|300.00'; got := (select count(*) || '|' || sum(amount) from public.payments where purchase_id = pu2); verdict := pg_temp.v(got, expected); return next;
  j := public.create_purchase(jsonb_build_object('company_id', ca, 'supplier_id', sa, 'status', 'draft', 'notes', 'ZZ_TEST', 'amount_paid', 200, 'items', jsonb_build_array(jsonb_build_object('product_id', pr, 'quantity', 30, 'unit_price', 10)))); pu3 := (j->>'id')::uuid;
  perform public.cancel_purchase(pu3);
  test := 'A cancelled draft never had payments'; expected := '0'; got := (select count(*) from public.payments where purchase_id = pu3)::text; verdict := pg_temp.v(got, expected); return next;
  j := public.create_purchase(jsonb_build_object('company_id', ca, 'supplier_id', sa, 'status', 'completed', 'notes', 'ZZ_TEST', 'items', jsonb_build_array(jsonb_build_object('product_id', pr, 'quantity', 10, 'unit_price', 80)))); pu4 := (j->>'id')::uuid;
  perform public.cancel_purchase(pu4);
  test := 'Paying a cancelled purchase refused'; expected := 'ERR P0001 DOCUMENT_CANCELLED'; got := pg_temp.try(format('select pg_temp.rp(%L, ''out'', %L, %L::jsonb)', ca, sa, jsonb_build_array(pg_temp.al(pu4, 10)))); verdict := pg_temp.v(got, expected); return next;
  test := 'Lowering amount paid below later supplier payments refused'; expected := 'ERR P0001 PAYMENTS_EXIST';
  got := pg_temp.try(format('select public.update_purchase(%L, %L::jsonb)', pu1, jsonb_build_object('supplier_id', sa, 'status', 'completed', 'notes', 'ZZ_TEST', 'invoice_number', 'ZZ-INV-1', 'amount_paid', 100, 'items', jsonb_build_array(jsonb_build_object('product_id', pr, 'quantity', 100, 'unit_price', 15))))); verdict := pg_temp.v(got, expected); return next;
  test := 'Ledger equals invoices (sales and purchases)'; expected := '0'; got := pg_temp.ledger_ok(); verdict := pg_temp.v(got, expected); return next;

  -- TEST 4-6: expenses
  insert into public.expenses(company_id, category_id, description, amount, expense_date) values (ca, ec_a, 'ZZ_TEST freight', 1000, today) returning id into e1;
  test := 'T4 expense Transport 1,000 appears (active, by me)'; expected := '1000.00|active|true|cash'; got := (select amount || '|' || status || '|' || (created_by = ua) || '|' || payment_method from public.expenses where id = e1); verdict := pg_temp.v(got, expected); return next;
  update public.expenses set amount = 1500 where id = e1;
  test := 'T5 edit 1,000 -> 1,500'; expected := '1500.00'; got := (select amount::text from public.expenses where id = e1); verdict := pg_temp.v(got, expected); return next;
  update public.expenses set status = 'cancelled', cancel_reason = 'duplicate' where id = e1;
  test := 'T6 cancel: status, who, when, reason'; expected := 'cancelled|true|true|duplicate'; got := (select status || '|' || (cancelled_by = ua) || '|' || (cancelled_at is not null) || '|' || cancel_reason from public.expenses where id = e1); verdict := pg_temp.v(got, expected); return next;
  test := 'T6 a cancelled expense cannot be edited'; expected := 'ERR P0001 EXPENSE_CANCELLED'; got := pg_temp.try(format('update public.expenses set amount = 99 where id = %L', e1)); verdict := pg_temp.v(got, expected); return next;
  test := 'T6 cancelling again / reactivating refused'; expected := 'ERR P0001 EXPENSE_CANCELLED'; got := pg_temp.try(format('update public.expenses set status = ''active'' where id = %L', e1)); verdict := pg_temp.v(got, expected); return next;
  insert into public.expenses(company_id, category_id, description, amount, expense_date, payment_method) values (ca, ec_a, 'ZZ_TEST diesel', 700, today, 'upi') returning id into e2;
  insert into public.expenses(company_id, category_id, description, amount, expense_date) values (ca, ec_a, 'ZZ_TEST porter', 300, today - 1) returning id into e3;
  test := 'Expense amount 0 refused'; expected := 'ERR 23514%'; got := pg_temp.try(format('insert into public.expenses(company_id, category_id, description, amount) values (%L, %L, ''ZZ_TEST x'', 0)', ca, ec_a)); verdict := pg_temp.v(got, expected); return next;
  test := 'Empty description refused'; expected := 'ERR 23514%'; got := pg_temp.try(format('insert into public.expenses(company_id, category_id, description, amount) values (%L, %L, ''   '', 5)', ca, ec_a)); verdict := pg_temp.v(got, expected); return next;
  test := 'Future date refused'; expected := 'ERR P0001 INVALID_DATE'; got := pg_temp.try(format('insert into public.expenses(company_id, category_id, description, amount, expense_date) values (%L, %L, ''ZZ_TEST x'', 5, %L)', ca, ec_a, today + 5)); verdict := pg_temp.v(got, expected); return next;
  test := 'Spoofing created_by refused'; expected := 'ERR 42501%'; got := pg_temp.try(format('insert into public.expenses(company_id, category_id, description, amount, created_by) values (%L, %L, ''ZZ_TEST x'', 5, %L)', ca, ec_a, ub)); verdict := pg_temp.v(got, expected); return next;
  test := 'Using Shop B''s category refused'; expected := 'ERR P0001 CATEGORY_INACTIVE'; got := pg_temp.try(format('insert into public.expenses(company_id, category_id, description, amount) values (%L, %L, ''ZZ_TEST x'', 5)', ca, ec_b)); verdict := pg_temp.v(got, expected); return next;
  test := 'Moving an expense to another shop refused'; expected := 'ERR P0001 COMPANY_IMMUTABLE'; got := pg_temp.try(format('update public.expenses set company_id = %L, category_id = %L where id = %L', cb, ec_b, e2)); verdict := pg_temp.v(got, expected); return next;
  test := 'Expenses cannot be deleted'; expected := 'ERR 42501%'; got := pg_temp.try(format('delete from public.expenses where id = %L', e2)); verdict := pg_temp.v(got, expected); return next;
  -- categories
  test := 'Default categories exist for the shop (9)'; expected := '9'; got := (select count(*) from public.expense_categories where company_id = ca and name in ('Rent','Electricity','Transport','Labour','Packaging','Maintenance','Fuel','Office','Other'))::text; verdict := pg_temp.v(got, expected); return next;
  insert into public.expense_categories(company_id, name) values (ca, ' ZZ_TEST Old Cat ');
  test := 'New category added (name trimmed)'; expected := 'ZZ_TEST Old Cat'; got := (select name from public.expense_categories where company_id = ca and name like 'ZZ\_TEST%'); verdict := pg_temp.v(got, expected); return next;
  test := 'Duplicate category name (any case) refused'; expected := 'ERR 23505%'; got := pg_temp.try(format('insert into public.expense_categories(company_id, name) values (%L, ''zz_test old cat'')', ca)); verdict := pg_temp.v(got, expected); return next;
  select id into ec_old from public.expense_categories where company_id = ca and name = 'ZZ_TEST Old Cat';
  update public.expense_categories set is_active = false where id = ec_old;
  test := 'Inactive category cannot be used for a new expense'; expected := 'ERR P0001 CATEGORY_INACTIVE'; got := pg_temp.try(format('insert into public.expenses(company_id, category_id, description, amount) values (%L, %L, ''ZZ_TEST x'', 5)', ca, ec_old)); verdict := pg_temp.v(got, expected); return next;

  -- figures
  st1 := public.finance_stats(ca, today);
  test := 'finance_stats moves by exactly the test data';
  expected := 'true|true|true|true|true';
  got := (((st1->>'today_expenses')::numeric - (st0->>'today_expenses')::numeric) = (select coalesce(sum(amount), 0) from public.expenses where description like 'ZZ\_TEST%' and status = 'active' and expense_date = today))::text
    || '|' || (((st1->>'money_in_today')::numeric - (st0->>'money_in_today')::numeric) = (select coalesce(sum(p.amount), 0) from public.payments p join public.sales s on s.id = p.sale_id where s.notes like 'ZZ\_TEST%' and s.status = 'completed' and p.status = 'completed' and p.payment_date = today))::text
    || '|' || (((st1->>'money_out_today')::numeric - (st0->>'money_out_today')::numeric) = (select coalesce(sum(p.amount), 0) from public.payments p join public.purchases u on u.id = p.purchase_id where u.notes like 'ZZ\_TEST%' and u.status = 'completed' and p.status = 'completed' and p.payment_date = today))::text
    || '|' || (((st1->>'receivable')::numeric - (st0->>'receivable')::numeric) = (select coalesce(sum(balance_due), 0) from public.sales where notes like 'ZZ\_TEST%' and status = 'completed'))::text
    || '|' || (((st1->>'payable')::numeric - (st0->>'payable')::numeric) = (select coalesce(sum(balance_due), 0) from public.purchases where notes like 'ZZ\_TEST%' and status = 'completed'))::text;
  verdict := pg_temp.v(got, expected); return next;
  test := 'Today''s expenses = 700 (1,000 cancelled, 300 is yesterday)'; expected := '700.00'; got := ((st1->>'today_expenses')::numeric - (st0->>'today_expenses')::numeric)::text; verdict := pg_temp.v(got, expected); return next;

  -- direct writes impossible
  test := 'Direct INSERT into payments blocked'; expected := 'ERR 42501%'; got := pg_temp.try(format('insert into public.payments(company_id, direction, kind, receipt_no, sale_id, party_name, doc_no, payment_method, amount, payment_date) values (%L, ''in'', ''payment'', ''RCT-999999'', %L, ''x'', ''x'', ''cash'', 1, current_date)', ca, s2)); verdict := pg_temp.v(got, expected); return next;
  test := 'Direct UPDATE of payments blocked'; expected := 'ERR 42501%'; got := pg_temp.try(format('update public.payments set amount = 1 where sale_id = %L', s2)); verdict := pg_temp.v(got, expected); return next;
  test := 'Direct DELETE of payments blocked'; expected := 'ERR 42501%'; got := pg_temp.try(format('delete from public.payments where sale_id = %L', s2)); verdict := pg_temp.v(got, expected); return next;
  test := 'Receipt counter not readable'; expected := 'ERR 42501%'; got := pg_temp.try('select * from public.payment_counters'); verdict := pg_temp.v(got, expected); return next;
  test := 'Internal ledger/seed functions not callable'; expected := 'ERR 42501%'; got := pg_temp.try(format('select public.expense_seed_categories(%L)', ca)); verdict := pg_temp.v(got, expected); return next;

  ---------------- Shop B (owner) ----------------
  reset role; perform pg_temp.login(ub);
  test := 'B sees none of A''s payments / expenses / categories'; expected := '0|0|0'; got := (select count(*) from public.payments where company_id = ca) || '|' || (select count(*) from public.expenses where company_id = ca) || '|' || (select count(*) from public.expense_categories where company_id = ca); verdict := pg_temp.v(got, expected); return next;
  test := 'B sees none of A''s sales'; expected := '0'; got := (select count(*) from public.sales where company_id = ca)::text; verdict := pg_temp.v(got, expected); return next;
  test := 'B receives a payment inside A (company_id = A)'; expected := 'ERR P0001 NOT_ALLOWED'; got := pg_temp.try(format('select pg_temp.rp(%L, ''in'', %L, %L::jsonb)', ca, cr, jsonb_build_array(pg_temp.al(s5, 10)))); verdict := pg_temp.v(got, expected); return next;
  test := 'B pays A''s invoice from its own shop'; expected := 'ERR P0001 DOCUMENT_NOT_FOUND'; got := pg_temp.try(format('select pg_temp.rp(%L, ''in'', %L, %L::jsonb)', cb, ck, jsonb_build_array(pg_temp.al(s5, 10)))); verdict := pg_temp.v(got, expected); return next;
  test := 'B voids A''s payment'; expected := 'ERR P0001 NOT_ALLOWED'; got := pg_temp.try(format('select public.void_payment(%L)', pay_id)); verdict := pg_temp.v(got, expected); return next;
  test := 'B inserts an expense into A'; expected := 'ERR 42501%'; got := pg_temp.try(format('insert into public.expenses(company_id, category_id, description, amount) values (%L, %L, ''ZZ_TEST hack'', 5)', ca, ec_a)); verdict := pg_temp.v(got, expected); return next;
  test := 'B edits A''s expense'; expected := 'OK rows=0'; got := pg_temp.try(format('update public.expenses set amount = 1 where id = %L', e2)); verdict := pg_temp.v(got, expected); return next;
  j := pg_temp.sale(cb, jsonb_build_array(pg_temp.item(pbr, 20)), 300, jsonb_build_object('customer_id', ck)); sb1 := (j->>'id')::uuid;
  j := pg_temp.rp(cb, 'in', ck, jsonb_build_array(pg_temp.al(sb1, 400)), jsonb_build_object('notes', 'ZZ_TEST'));
  test := 'B''s receipt numbering is its own sequence'; expected := 'RCT-' || lpad((coalesce(c_pin_b, 0) + 1)::text, 6, '0'); got := j->>'receipt_no'; verdict := pg_temp.v(got, expected); return next;
  test := 'B sees only its own 2 payments (300 at billing + 400 later)'; expected := '2|700.00'; got := (select count(*) || '|' || sum(amount) from public.payments where doc_no in (select invoice_no from public.sales where notes like 'ZZ\_TEST%')); verdict := pg_temp.v(got, expected); return next;
  insert into public.expenses(company_id, category_id, description, amount) values (cb, ec_b, 'ZZ_TEST B rent', 5000);
  test := 'B sees only its own expense'; expected := '1'; got := (select count(*) from public.expenses where description like 'ZZ\_TEST%')::text; verdict := pg_temp.v(got, expected); return next;

  ---------------- Shop A again ----------------
  reset role; perform pg_temp.login(ua);
  test := 'A sees none of B''s payments / expenses'; expected := '0|0'; got := (select count(*) from public.payments where company_id = cb) || '|' || (select count(*) from public.expenses where company_id = cb); verdict := pg_temp.v(got, expected); return next;
  test := 'A voids B''s payment'; expected := 'ERR P0001 NOT_ALLOWED'; got := pg_temp.try(format('select public.void_payment(%L)', (select id from public.payments where company_id = cb limit 1))); verdict := pg_temp.v(got, expected); return next;

  ---------------- Shop B demoted to cashier (reverted below) ----------------
  reset role;
  update public.company_members set role = 'cashier' where user_id = ub and company_id = cb;
  perform pg_temp.login(ub);
  test := 'Cashier can read payments'; expected := '2'; got := (select count(*) from public.payments where company_id = cb and doc_no in (select invoice_no from public.sales where notes like 'ZZ\_TEST%'))::text; verdict := pg_temp.v(got, expected); return next;
  j := pg_temp.sale(cb, jsonb_build_array(pg_temp.item(pbr, 10)), 0, jsonb_build_object('customer_id', ck, 'payment_method', 'credit'));
  j := pg_temp.rp(cb, 'in', ck, jsonb_build_array(pg_temp.al((j->>'id')::uuid, 100)), jsonb_build_object('notes', 'ZZ_TEST'));
  test := 'Cashier CAN receive a customer payment'; expected := 'RCT-%'; got := j->>'receipt_no'; verdict := pg_temp.v(got, expected); return next;
  test := 'Cashier cannot pay a supplier'; expected := 'ERR P0001 NOT_ALLOWED'; got := pg_temp.try(format('select pg_temp.rp(%L, ''out'', %L, %L::jsonb)', cb, sbp, jsonb_build_array(pg_temp.al(gen_random_uuid(), 10)))); verdict := pg_temp.v(got, expected); return next;
  test := 'Cashier cannot void a payment'; expected := 'ERR P0001 NOT_ALLOWED'; got := pg_temp.try(format('select public.void_payment(%L)', (select id from public.payments where company_id = cb and kind = 'payment' limit 1))); verdict := pg_temp.v(got, expected); return next;
  test := 'Cashier cannot read expenses or categories'; expected := '0|0'; got := (select count(*) from public.expenses) || '|' || (select count(*) from public.expense_categories); verdict := pg_temp.v(got, expected); return next;
  test := 'Cashier cannot add an expense'; expected := 'ERR 42501%'; got := pg_temp.try(format('insert into public.expenses(company_id, category_id, description, amount) values (%L, %L, ''ZZ_TEST x'', 5)', cb, ec_b)); verdict := pg_temp.v(got, expected); return next;
  test := 'Cashier cannot add a category'; expected := 'ERR 42501%'; got := pg_temp.try(format('insert into public.expense_categories(company_id, name) values (%L, ''ZZ_TEST nope'')', cb)); verdict := pg_temp.v(got, expected); return next;
  test := 'Cashier sees no expense figures'; expected := '0'; got := (public.finance_stats(cb, today)->>'today_expenses'); verdict := pg_temp.v(got, expected || '%'); return next;

  ---------------- Not logged in ----------------
  reset role; set local role anon;
  test := 'Anonymous cannot read payments'; expected := 'ERR 42501%'; got := pg_temp.try('select 1 from public.payments'); verdict := pg_temp.v(got, expected); return next;
  test := 'Anonymous cannot read expenses'; expected := 'ERR 42501%'; got := pg_temp.try('select 1 from public.expenses'); verdict := pg_temp.v(got, expected); return next;
  test := 'Anonymous cannot record a payment'; expected := 'ERR 42501%'; got := pg_temp.try(format('select public.record_payments(%L::jsonb)', jsonb_build_object('company_id', ca))); verdict := pg_temp.v(got, expected); return next;

  ---------------- A brand-new shop gets the default categories ----------------
  reset role;
  insert into public.companies(name) values ('ZZ_TEST New Shop') returning id into newco;
  test := 'A new shop is given the 9 default expense categories'; expected := '9'; got := (select count(*) from public.expense_categories where company_id = newco)::text; verdict := pg_temp.v(got, expected); return next;
  test := 'Final check: ledger equals invoices'; expected := '0'; got := pg_temp.ledger_ok(); verdict := pg_temp.v(got, expected); return next;

  ---------------- Clean up everything this test created ----------------
  update public.company_members set role = role_b where user_id = ub and company_id = cb;
  delete from public.audit_logs where company_id in (ca, cb) and created_at >= now();
  delete from public.sales where notes like 'ZZ\_TEST%';          -- also removes their payment rows
  delete from public.purchases where notes like 'ZZ\_TEST%';
  delete from public.expenses where description like 'ZZ\_TEST%';
  delete from public.expense_categories where name like 'ZZ\_TEST%';
  delete from public.inventory_movements where product_id in (select id from public.products where product_name like 'ZZ\_TEST%');
  delete from public.products where product_name like 'ZZ\_TEST%';
  delete from public.categories where name like 'ZZ\_TEST%';
  delete from public.customers where customer_name like 'ZZ\_TEST%';
  delete from public.suppliers where supplier_name like 'ZZ\_TEST%';
  delete from public.companies where name like 'ZZ\_TEST%';
  if c_sin is null then delete from public.sale_counters where company_id = ca; else update public.sale_counters set last_no = c_sin where company_id = ca; end if;
  if c_sin_b is null then delete from public.sale_counters where company_id = cb; else update public.sale_counters set last_no = c_sin_b where company_id = cb; end if;
  if c_pin is null then delete from public.purchase_counters where company_id = ca; else update public.purchase_counters set last_no = c_pin where company_id = ca; end if;
  if c_ppin_b is null then delete from public.purchase_counters where company_id = cb; else update public.purchase_counters set last_no = c_ppin_b where company_id = cb; end if;
  delete from public.payment_counters where company_id in (ca, cb);
  if c_ppin is not null then insert into public.payment_counters values (ca, 'in', c_ppin); end if;
  if c_ppout is not null then insert into public.payment_counters values (ca, 'out', c_ppout); end if;
  if c_pin_b is not null then insert into public.payment_counters values (cb, 'in', c_pin_b); end if;
  test := 'Cleanup: no test data left, Shop B role restored'; expected := '0|0|0|0|0|' || role_b;
  got := (select count(*) from public.sales where notes like 'ZZ\_TEST%') || '|' || (select count(*) from public.expenses where description like 'ZZ\_TEST%') || '|' || (select count(*) from public.customers where customer_name like 'ZZ\_TEST%')
      || '|' || (select count(*) from public.companies where name like 'ZZ\_TEST%') || '|' || (select count(*) from public.payments where party_name like 'ZZ\_TEST%') || '|' || (select role from public.company_members where user_id = ub and company_id = cb);
  verdict := pg_temp.v(got, expected); return next;
  return;
end $$;

select * from pg_temp.phase6_test();
