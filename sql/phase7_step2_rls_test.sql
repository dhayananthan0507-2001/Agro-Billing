-- Agro POS — Phase 7 Step 2 test: Reports & Analytics (calculations, date ranges, empty results, permissions, shop isolation). Run in the Supabase SQL Editor.
--
-- BEFORE RUNNING: replace the two emails below with the logins of two DIFFERENT shops (Shop A and Shop B), then Run.
-- You get one table of PASS/FAIL rows. The test creates 'ZZ_TEST ...' data dated YEARS in the past (a window your real sales cannot touch;
-- it checks that first and moves further back if needed), checks every report against hand-computed numbers, then DELETES everything it
-- created and restores the counters, shop settings and memberships it touched. One transaction: any unexpected error rolls it all back.
-- Your real data is never changed.

create or replace function pg_temp.try(q text) returns text language plpgsql as $$
declare n bigint;
begin execute q; get diagnostics n = row_count; return 'OK rows=' || n;
exception when others then return 'ERR ' || sqlstate || ' ' || sqlerrm;
end $$;
-- numbers are compared by VALUE: 2570.00 = 2570, 5.000 = 5, 200.00000 = 200 (the page formats money itself)
create or replace function pg_temp.nz(s text) returns text language sql immutable as
$$ select regexp_replace(regexp_replace(s, '(\.\d*[1-9])0+(?!\d)', '\1', 'g'), '\.0+(?!\d)', '', 'g') $$;
create or replace function pg_temp.c(t text, e text, g text) returns table(test text, expected text, got text, verdict text) language sql as
$$ select t, e, g, case when pg_temp.nz(g) is not distinct from pg_temp.nz(e) or g like e then 'PASS' else 'FAIL' end $$;
create or replace function pg_temp.login(u uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', u::text, true);
  execute 'set local role authenticated';
end $$;
create or replace function pg_temp.item(pid uuid, qty numeric, price numeric default 50, disc numeric default 0) returns jsonb language sql as
$$ select jsonb_build_object('product_id', pid, 'quantity', qty, 'unit_price', price, 'discount', disc) $$;
create or replace function pg_temp.sale(cid uuid, items jsonb, paid numeric, extra jsonb default '{}'::jsonb) returns jsonb language sql as
$$ select public.create_sale(jsonb_build_object('company_id', cid, 'notes', 'ZZ_TEST', 'payment_method', 'cash', 'amount_paid', paid, 'items', items) || extra) $$;
create or replace function pg_temp.rp(cid uuid, dir text, party uuid, allocs jsonb) returns jsonb language sql as
$$ select public.record_payments(jsonb_build_object('company_id', cid, 'direction', dir, 'party_id', party, 'payment_method', 'cash', 'allocations', allocs)) $$;
create or replace function pg_temp.al(doc uuid, amt numeric) returns jsonb language sql as $$ select jsonb_build_object('doc_id', doc, 'amount', amt) $$;
create or replace function pg_temp.names(arr jsonb) returns text language sql as
$$ select coalesce(string_agg(x->>'product_name', ',' order by x->>'product_name'), 'none') from jsonb_array_elements(arr) x where x->>'product_name' like 'ZZ\_TEST%' $$;
create or replace function pg_temp.zrow(arr jsonb, key text, val text) returns jsonb language sql as $$ select x from jsonb_array_elements(arr) x where x->>key = val limit 1 $$;
create or replace function pg_temp.ledger_ok() returns text language sql as $$
  select ((select count(*) from public.sales s where s.notes like 'ZZ\_TEST%' and s.amount_paid <> coalesce((select sum(amount) from public.payments where sale_id = s.id and status = 'completed'), 0))
        + (select count(*) from public.purchases u where u.notes like 'ZZ\_TEST%' and u.completed_at is not null and u.amount_paid <> coalesce((select sum(amount) from public.payments where purchase_id = u.id and status = 'completed'), 0)))::text $$;

create or replace function pg_temp.step2_test() returns table(test text, expected text, got text, verdict text)
language plpgsql as $$
declare
  email_a text := 'CHANGE_ME_shop_a@example.com';   -- <<< Shop A login email
  email_b text := 'CHANGE_ME_shop_b@example.com';   -- <<< Shop B login email
  ua uuid; ub uuid; ca uuid; cb uuid; today date := public.today_ist(); bd date; w1 date; w2 date; ew1 date; ew2 date; pw1 date; pw2 date;
  cat_a uuid; cat_b uuid; pr uuid; pw uuid; pnc uuid; pl1 uuid; pl2 uuid; pl3 uuid; pout uuid; pfine uuid; pexp uuid; pval uuid; pbr uuid; ec uuid; ecn text;
  cr uuid; co uuid; sa uuid; sx uuid; sr uuid; sbp uuid; s1 uuid; s2 uuid; s3 uuid; s4 uuid; s5 uuid; s_old uuid; s_mid uuid; s_now uuid; s_c uuid; ps1 uuid; pay_old uuid;
  ctr_s_a int; ctr_s_b int; ctr_p_a int; ctr_p_b int; ctr_in_a int; ctr_out_a int; ctr_in_b int; ctr_out_b int; set_a company_settings; had_b_member boolean;
  j jsonb; k jsonb; x jsonb; i int; n_denied int; q text;
begin
  select id into ua from auth.users where lower(email) = lower(email_a);
  select id into ub from auth.users where lower(email) = lower(email_b);
  if ua is null or ub is null then raise exception 'Could not find one of the two emails in auth.users. Edit email_a / email_b.'; end if;
  select company_id into ca from public.company_members where user_id = ua limit 1;
  select company_id into cb from public.company_members where user_id = ub limit 1;
  if ca is null or cb is null then raise exception 'One of the accounts has no shop yet (log in once first).'; end if;
  if ca = cb then raise exception 'Both emails belong to the same shop. Use two different shops.'; end if;
  select id, name into ec, ecn from public.expense_categories where company_id = ca and lower(name) = 'transport';
  if ec is null then raise exception 'Default expense categories are missing. Run phase6_payments_expenses.sql first.'; end if;

  select last_no into ctr_s_a from public.sale_counters where company_id = ca;     select last_no into ctr_s_b from public.sale_counters where company_id = cb;
  select last_no into ctr_p_a from public.purchase_counters where company_id = ca; select last_no into ctr_p_b from public.purchase_counters where company_id = cb;
  select last_no into ctr_in_a from public.payment_counters where company_id = ca and direction = 'in';  select last_no into ctr_out_a from public.payment_counters where company_id = ca and direction = 'out';
  select last_no into ctr_in_b from public.payment_counters where company_id = cb and direction = 'in';   select last_no into ctr_out_b from public.payment_counters where company_id = cb and direction = 'out';
  select * into set_a from public.company_settings where company_id = ca;
  had_b_member := exists (select 1 from public.company_members where company_id = ca and user_id = ub);

  -- leftovers from an interrupted earlier run
  delete from public.sales where notes like 'ZZ\_TEST%';  delete from public.payments where party_name like 'ZZ\_TEST%' or doc_no in (select invoice_no from public.sales where notes like 'ZZ\_TEST%');
  delete from public.purchases where notes like 'ZZ\_TEST%';  delete from public.expenses where description like 'ZZ\_TEST%';
  delete from public.inventory_movements where product_id in (select id from public.products where product_name like 'ZZ\_TEST%');
  delete from public.products where product_name like 'ZZ\_TEST%';  delete from public.categories where name like 'ZZ\_TEST%';
  delete from public.customers where customer_name like 'ZZ\_TEST%';  delete from public.suppliers where supplier_name like 'ZZ\_TEST%';

  -- a window of dates in the far past that holds NONE of your real data (moves back until it is empty)
  bd := today - 1500;
  for i in 1..10 loop
    exit when not exists (select 1 from public.sales where company_id in (ca, cb) and sale_date between bd - 210 and bd + 15)
          and not exists (select 1 from public.purchases where company_id in (ca, cb) and purchase_date between bd - 210 and bd + 15)
          and not exists (select 1 from public.expenses where company_id in (ca, cb) and expense_date between bd - 210 and bd + 15)
          and not exists (select 1 from public.payments where company_id in (ca, cb) and payment_date between bd - 210 and bd + 15);
    bd := bd - 300;
  end loop;
  if bd < date '2000-01-01' + 215 then raise exception 'Could not find an empty date window.'; end if;
  w1 := bd; w2 := bd + 9; ew1 := bd - 200; ew2 := bd - 190; pw1 := bd - 65; pw2 := bd - 55;

  -- seed as table owner (bypasses RLS)
  insert into public.categories(company_id, name) values (ca, 'ZZ_TEST Cat') returning id into cat_a;
  insert into public.categories(company_id, name) values (cb, 'ZZ_TEST Cat') returning id into cat_b;
  insert into public.products(company_id, category_id, product_name, unit, selling_price, tax_rate, minimum_stock) values (ca, cat_a, 'ZZ_TEST Rice', 'Kg', 50, 0, 0) returning id into pr;
  insert into public.products(company_id, category_id, product_name, unit, selling_price, tax_rate, minimum_stock) values (ca, cat_a, 'ZZ_TEST Wheat', 'Kg', 40, 5, 0) returning id into pw;
  insert into public.products(company_id, category_id, product_name, unit, selling_price, tax_rate, minimum_stock) values (ca, cat_a, 'ZZ_TEST NoCost', 'Kg', 100, 0, 0) returning id into pnc;
  insert into public.products(company_id, category_id, product_name, unit, selling_price, minimum_stock) values (ca, cat_a, 'ZZ_TEST Low1', 'Kg', 10, 0) returning id into pl1;
  insert into public.products(company_id, category_id, product_name, unit, selling_price, minimum_stock) values (ca, cat_a, 'ZZ_TEST Low2', 'Kg', 10, 5) returning id into pl2;
  insert into public.products(company_id, category_id, product_name, unit, selling_price, minimum_stock) values (ca, cat_a, 'ZZ_TEST Low3', 'Kg', 10, 5) returning id into pl3;
  insert into public.products(company_id, category_id, product_name, unit, selling_price, minimum_stock) values (ca, cat_a, 'ZZ_TEST Out', 'Kg', 10, 0) returning id into pout;
  insert into public.products(company_id, category_id, product_name, unit, selling_price, minimum_stock) values (ca, cat_a, 'ZZ_TEST Fine', 'Kg', 10, 0) returning id into pfine;
  insert into public.products(company_id, category_id, product_name, unit, selling_price) values (ca, cat_a, 'ZZ_TEST ExpSeed', 'Kg', 10) returning id into pexp;
  insert into public.products(company_id, category_id, product_name, unit, selling_price) values (ca, cat_a, 'ZZ_TEST Val', 'Kg', 10) returning id into pval;
  insert into public.products(company_id, category_id, product_name, unit, selling_price) values (cb, cat_b, 'ZZ_TEST Rice B', 'Kg', 50) returning id into pbr;
  insert into public.inventory(company_id, product_id, quantity) values (ca, pr, 1000), (ca, pw, 1000), (ca, pnc, 100), (ca, pl1, 5), (ca, pl2, 8), (ca, pl3, 4), (ca, pout, 0), (ca, pfine, 100), (ca, pexp, 29), (ca, pval, 15), (cb, pbr, 100);
  insert into public.product_batches(company_id, product_id, batch_number, quantity, purchase_price) values (ca, pr, 'OPENING', 1000, 30), (ca, pw, 'OPENING', 1000, 25), (ca, pnc, 'OPENING', 100, 0);
  insert into public.product_batches(company_id, product_id, batch_number, quantity, purchase_price) values (ca, pl1, 'B', 5, 10), (ca, pl2, 'B', 8, 10), (ca, pl3, 'B', 4, 10), (ca, pfine, 'B', 100, 10), (cb, pbr, 'B', 100, 10);
  insert into public.product_batches(company_id, product_id, batch_number, quantity, purchase_price, expiry_date) values
    (ca, pexp, 'EXPD', 10, 20, today - 3), (ca, pexp, 'EXP2', 4, 20, today - 1), (ca, pexp, 'SOON', 5, 20, today + 10), (ca, pexp, 'FAR', 7, 20, today + 90), (ca, pexp, 'ZEROQ', 0, 20, today - 2);
  insert into public.product_batches(company_id, product_id, batch_number, quantity, purchase_price) values (ca, pexp, 'NOEXP', 3, 20), (ca, pval, 'V1', 10, 20), (ca, pval, 'V2', 5, 0);
  insert into public.customers(company_id, customer_name, phone, opening_balance, balance_type) values (ca, 'ZZ_TEST Ramesh', '9876543210', 1000, 'debit') returning id into cr;
  insert into public.customers(company_id, customer_name, phone, opening_balance, balance_type) values (ca, 'ZZ_TEST Advance', '9876543211', 300, 'credit') returning id into co;
  insert into public.suppliers(company_id, supplier_name, phone, opening_balance, balance_type) values (ca, 'ZZ_TEST ABC Agro', '9876500000', 800, 'credit') returning id into sa;
  insert into public.suppliers(company_id, supplier_name, phone, opening_balance, balance_type) values (ca, 'ZZ_TEST XYZ Agro', '9876500001', 200, 'debit') returning id into sx;
  insert into public.suppliers(company_id, supplier_name, phone) values (ca, 'ZZ_TEST Report Supplier', '9876500002') returning id into sr;
  insert into public.suppliers(company_id, supplier_name, phone) values (cb, 'ZZ_TEST B Supplier', '9123400000') returning id into sbp;
  update public.company_settings set low_stock_threshold = 10, expiry_alert_days = 30 where company_id = ca;

  ---------------- Shop A owner creates the transactions through the real application functions ----------------
  perform pg_temp.login(ua);
  j := pg_temp.sale(ca, jsonb_build_array(pg_temp.item(pr, 10)), 500, jsonb_build_object('sale_date', bd + 3)); s1 := (j->>'id')::uuid;
  j := pg_temp.sale(ca, jsonb_build_array(pg_temp.item(pw, 20, 40)), 800, jsonb_build_object('sale_date', bd + 3, 'discount', 40)); s2 := (j->>'id')::uuid;
  j := pg_temp.sale(ca, jsonb_build_array(pg_temp.item(pnc, 5, 100)), 500, jsonb_build_object('sale_date', bd + 3)); s3 := (j->>'id')::uuid;
  j := pg_temp.sale(ca, jsonb_build_array(pg_temp.item(pr, 5)), 250, jsonb_build_object('sale_date', bd + 3)); s4 := (j->>'id')::uuid; perform public.cancel_sale(s4);
  j := pg_temp.sale(ca, jsonb_build_array(pg_temp.item(pr, 10), pg_temp.item(pw, 10, 40)), 830, jsonb_build_object('sale_date', bd + 3, 'discount', 90)); s5 := (j->>'id')::uuid;
  perform pg_temp.sale(ca, jsonb_build_array(pg_temp.item(pr, 2)), 100, jsonb_build_object('sale_date', bd - 60));        -- two sales on different days, outside the main window
  perform pg_temp.sale(ca, jsonb_build_array(pg_temp.item(pr, 1)), 50, jsonb_build_object('sale_date', bd - 61));
  perform public.create_purchase(jsonb_build_object('company_id', ca, 'supplier_id', sr, 'status', 'completed', 'notes', 'ZZ_TEST', 'purchase_date', bd + 5, 'additional_charges', 50, 'amount_paid', 1000,
        'items', jsonb_build_array(jsonb_build_object('product_id', pr, 'quantity', 100, 'unit_price', 30))));
  perform public.create_purchase(jsonb_build_object('company_id', ca, 'supplier_id', sr, 'status', 'completed', 'notes', 'ZZ_TEST', 'purchase_date', bd + 5, 'amount_paid', 1050,
        'items', jsonb_build_array(jsonb_build_object('product_id', pw, 'quantity', 40, 'unit_price', 25, 'tax_rate', 5))));
  perform public.create_purchase(jsonb_build_object('company_id', ca, 'supplier_id', sr, 'status', 'draft', 'notes', 'ZZ_TEST', 'purchase_date', bd + 5, 'items', jsonb_build_array(jsonb_build_object('product_id', pr, 'quantity', 1, 'unit_price', 30))));
  j := public.create_purchase(jsonb_build_object('company_id', ca, 'supplier_id', sr, 'status', 'completed', 'notes', 'ZZ_TEST', 'purchase_date', bd + 5, 'items', jsonb_build_array(jsonb_build_object('product_id', pr, 'quantity', 1, 'unit_price', 30)))); perform public.cancel_purchase((j->>'id')::uuid);
  insert into public.expenses(company_id, category_id, description, amount, expense_date) values (ca, ec, 'ZZ_TEST freight', 300, bd + 7);
  insert into public.expenses(company_id, category_id, description, amount, expense_date) values (ca, ec, 'ZZ_TEST void me', 200, bd + 7);
  update public.expenses set status = 'cancelled', cancel_reason = 'test' where description = 'ZZ_TEST void me';
  -- customers and suppliers with real balances (recent dates, so the ageing buckets are meaningful)
  j := pg_temp.sale(ca, jsonb_build_array(pg_temp.item(pr, 4)), 0, jsonb_build_object('customer_id', cr, 'payment_method', 'credit', 'sale_date', today - 40)); s_old := (j->>'id')::uuid;       -- 200
  j := pg_temp.sale(ca, jsonb_build_array(pg_temp.item(pr, 10)), 0, jsonb_build_object('customer_id', cr, 'payment_method', 'credit', 'sale_date', today - 20)); s_mid := (j->>'id')::uuid;      -- 500
  j := pg_temp.sale(ca, jsonb_build_array(pg_temp.item(pr, 6)), 100, jsonb_build_object('customer_id', cr, 'payment_method', 'credit', 'sale_date', today)); s_now := (j->>'id')::uuid;          -- 300, 100 paid
  j := pg_temp.sale(ca, jsonb_build_array(pg_temp.item(pr, 5)), 0, jsonb_build_object('customer_id', cr, 'payment_method', 'credit', 'sale_date', today - 15)); s_c := (j->>'id')::uuid; perform public.cancel_sale(s_c);
  perform pg_temp.rp(ca, 'in', cr, jsonb_build_array(pg_temp.al(s_mid, 300)));                       -- later payment on s_mid: 500 -> 200 due
  perform pg_temp.rp(ca, 'in', cr, jsonb_build_array(pg_temp.al(s_old, 50)));                        -- paid 50 ...
  select id into pay_old from public.payments where sale_id = s_old and kind = 'payment' and status = 'completed';
  perform public.void_payment(pay_old, 'entered by mistake');                                       -- ... then voided: s_old is 200 due again
  j := public.create_purchase(jsonb_build_object('company_id', ca, 'supplier_id', sa, 'status', 'completed', 'notes', 'ZZ_TEST', 'purchase_date', today - 25, 'amount_paid', 100,
        'items', jsonb_build_array(jsonb_build_object('product_id', pr, 'quantity', 10, 'unit_price', 30)))); ps1 := (j->>'id')::uuid;      -- 300, 100 paid, 200 due
  perform pg_temp.rp(ca, 'out', sa, jsonb_build_array(pg_temp.al(ps1, 150)));                        -- supplier payment 150 -> 50 due

  ---------------- SALES ----------------
  j := public.report_sales(ca, w1, w2, 'day');
  return query select * from pg_temp.c('Sales: 4 bills, net 2,570, GST 60, total 2,630, paid 2,630; cancelled 1 bill / 250', '4|2570.00|60.00|2630.00|2630.00|1|250.00',
    (j->'totals'->>'bills') || '|' || (j->'totals'->>'net') || '|' || (j->'totals'->>'gst') || '|' || (j->'totals'->>'total') || '|' || (j->'totals'->>'paid') || '|' || (j->'cancelled'->>'bills') || '|' || (j->'cancelled'->>'total'));
  return query select * from pg_temp.c('Sales: payment method summary (bills made by cash: 4, 2,630)', 'cash|4|2630.00', (j->'by_method'->0->>'method') || '|' || (j->'by_method'->0->>'bills') || '|' || (j->'by_method'->0->>'total'));
  return query select * from pg_temp.c('Sales: money actually received (from the payment records): 2,630 in 4 payments; the cancelled sale''s payment is left out', '2630.00|cash|4|2630.00',
    (j->'received'->>'total') || '|' || (j->'received'->'rows'->0->>'method') || '|' || (j->'received'->'rows'->0->>'payments') || '|' || (j->'received'->'rows'->0->>'total'));
  return query select * from pg_temp.c('Sales by DAY: one trading day -> 1 row with all 4 bills', '1|4|2570.00', jsonb_array_length(j->'rows') || '|' || (j->'rows'->0->>'bills') || '|' || (j->'rows'->0->>'net'));
  return query select * from pg_temp.c('Sales by WEEK: rows add up to the same totals', 'true|true', (jsonb_array_length(public.report_sales(ca, w1, w2, 'week')->'rows') >= 1)::text || '|' || ((select sum((r->>'net')::numeric) from jsonb_array_elements(public.report_sales(ca, w1, w2, 'week')->'rows') r) = 2570)::text);
  return query select * from pg_temp.c('Sales by MONTH: rows add up to the same totals', 'true', ((select sum((r->>'total')::numeric) from jsonb_array_elements(public.report_sales(ca, w1, w2, 'month')->'rows') r) = 2630)::text);
  j := public.report_sales(ca, pw1, pw2, 'day'); k := public.report_sales(ca, pw1, pw2, 'week');
  return query select * from pg_temp.c('Sales, another date range (2 sales on 2 different days): by day 2 rows, 2 bills, net 150; by week and month the same total', '2|2|150.00|true|true',
    jsonb_array_length(j->'rows') || '|' || (j->'totals'->>'bills') || '|' || (j->'totals'->>'net') || '|' || ((select sum((r->>'net')::numeric) from jsonb_array_elements(k->'rows') r) = 150)::text
      || '|' || ((select sum((r->>'net')::numeric) from jsonb_array_elements(public.report_sales(ca, pw1, pw2, 'month')->'rows') r) = 150)::text);
  j := public.report_sales(ca, ew1, ew2, 'day');
  return query select * from pg_temp.c('Sales, EMPTY range: no rows, zero totals, nothing cancelled, no payments', '0|0|0.00|0.00|0|0|0.00',
    jsonb_array_length(j->'rows') || '|' || (j->'totals'->>'bills') || '|' || (j->'totals'->>'net') || '|' || (j->'totals'->>'total') || '|' || jsonb_array_length(j->'by_method') || '|' || (j->'cancelled'->>'bills') || '|' || (j->'received'->>'total'));
  return query select * from pg_temp.c('Sales: a one-day range hits exactly that day (bd+3 -> 4 bills; the day before -> 0)', '4|0',
    (public.report_sales(ca, bd + 3, bd + 3, 'day')->'totals'->>'bills') || '|' || (public.report_sales(ca, bd + 2, bd + 2, 'day')->'totals'->>'bills'));
  return query select * from pg_temp.c('Range rules: start after end / missing dates / over ~3 years are refused', 'ERR P0001 INVALID_RANGE|ERR P0001 INVALID_RANGE|ERR P0001 RANGE_TOO_LARGE',
    pg_temp.try(format('select public.report_sales(%L, %L, %L)', ca, w2, w1)) || '|' || pg_temp.try(format('select public.report_sales(%L, NULL, NULL)', ca)) || '|' || pg_temp.try(format('select public.report_sales(%L, %L, %L)', ca, today - 2000, today)));

  ---------------- PURCHASES ----------------
  j := public.report_purchases(ca, w1, w2, 'day');
  return query select * from pg_temp.c('Purchases: 2 bills, net 4,050 (incl. 50 charges), GST 50, total 4,100, due 2,050; 1 cancelled; the draft is excluded', '2|4050.00|50.00|4100.00|2050.00|1',
    (j->'totals'->>'bills') || '|' || (j->'totals'->>'net') || '|' || (j->'totals'->>'gst') || '|' || (j->'totals'->>'total') || '|' || (j->'totals'->>'due') || '|' || (j->'cancelled'->>'bills'));
  return query select * from pg_temp.c('Purchases by supplier: name | bills | total | paid | due', 'ZZ_TEST Report Supplier|2|4100.00|2050.00|2050.00',
    (j->'by_supplier'->0->>'name') || '|' || (j->'by_supplier'->0->>'bills') || '|' || (j->'by_supplier'->0->>'total') || '|' || (j->'by_supplier'->0->>'paid') || '|' || (j->'by_supplier'->0->>'due'));
  return query select * from pg_temp.c('Purchases date-wise: day 1 row (2 bills); week and month rows add up to 4,100', '1|2|true|true',
    jsonb_array_length(j->'rows') || '|' || (j->'rows'->0->>'bills') || '|' || ((select sum((r->>'total')::numeric) from jsonb_array_elements(public.report_purchases(ca, w1, w2, 'week')->'rows') r) = 4100)::text
      || '|' || ((select sum((r->>'total')::numeric) from jsonb_array_elements(public.report_purchases(ca, w1, w2, 'month')->'rows') r) = 4100)::text);
  j := public.report_purchases(ca, ew1, ew2, 'day');
  return query select * from pg_temp.c('Purchases, EMPTY range: no rows, no suppliers, zero totals', '0|0|0|0.00', jsonb_array_length(j->'rows') || '|' || jsonb_array_length(j->'by_supplier') || '|' || (j->'totals'->>'bills') || '|' || (j->'totals'->>'total'));

  ---------------- EXPENSES ----------------
  j := public.report_expenses(ca, w1, w2, 'day');
  return query select * from pg_temp.c('Expenses: total 300 in 1 entry; the cancelled 200 is separate', '300.00|1|1|200.00', (j->>'total') || '|' || (j->>'count') || '|' || (j->'cancelled'->>'count') || '|' || (j->'cancelled'->>'total'));
  return query select * from pg_temp.c('Expenses by category (Transport 300) and date-wise (1 day row of 300)', ecn || '|1|300.00|1|300.00',
    (j->'by_category'->0->>'category') || '|' || (j->'by_category'->0->>'count') || '|' || (j->'by_category'->0->>'total') || '|' || jsonb_array_length(j->'rows') || '|' || (j->'rows'->0->>'total'));
  return query select * from pg_temp.c('Expenses by week / month add up to 300', 'true|true', ((select sum((r->>'total')::numeric) from jsonb_array_elements(public.report_expenses(ca, w1, w2, 'week')->'rows') r) = 300)::text
      || '|' || ((select sum((r->>'total')::numeric) from jsonb_array_elements(public.report_expenses(ca, w1, w2, 'month')->'rows') r) = 300)::text);
  j := public.report_expenses(ca, ew1, ew2, 'day');
  return query select * from pg_temp.c('Expenses, EMPTY range: nothing', '0.00|0|0|0', (j->>'total') || '|' || (j->>'count') || '|' || jsonb_array_length(j->'by_category') || '|' || jsonb_array_length(j->'rows'));

  ---------------- GST (sales, by rate) ----------------
  j := public.report_gst(ca, w1, w2);
  return query select * from pg_temp.c('GST by rate: 0% = 3 lines / taxable 1,500 / tax 0; 5% = 2 lines / 1,200 / 60', '0.00:3:1500.00:0.00|5.00:2:1200.00:60.00',
    (j->'rows'->0->>'rate') || ':' || (j->'rows'->0->>'lines') || ':' || (j->'rows'->0->>'taxable') || ':' || (j->'rows'->0->>'tax') || '|' || (j->'rows'->1->>'rate') || ':' || (j->'rows'->1->>'lines') || ':' || (j->'rows'->1->>'taxable') || ':' || (j->'rows'->1->>'tax'));
  return query select * from pg_temp.c('GST totals: taxable 2,700, tax 60, 4 bills; bill discounts 130 are reported apart; cancelled sale excluded', '2700.00|60.00|4|130.00', (j->'totals'->>'taxable') || '|' || (j->'totals'->>'tax') || '|' || (j->'totals'->>'bills') || '|' || (j->>'bill_discount'));
  j := public.report_gst(ca, ew1, ew2);
  return query select * from pg_temp.c('GST, EMPTY range: no rates, zero', '0|0.00|0.00', jsonb_array_length(j->'rows') || '|' || (j->'totals'->>'taxable') || '|' || (j->'totals'->>'tax'));

  ---------------- ESTIMATED GROSS MARGIN (batch cost) ----------------
  j := public.report_products(ca, w1, w2, 300);
  return query select * from pg_temp.c('Margin totals: sales 2,570; costed 2,070; cost 1,350; margin 720; uncosted 500; 3 products, 1 without cost', '2570.00|2070.00|1350.00|720.00|500.00|3|1',
    (j->'totals'->>'revenue') || '|' || (j->'totals'->>'revenue_costed') || '|' || (j->'totals'->>'cost') || '|' || (j->'totals'->>'margin') || '|' || (j->'totals'->>'revenue_uncosted') || '|' || (j->'totals'->>'products') || '|' || (j->'totals'->>'products_cost_missing'));
  x := pg_temp.zrow(j->'rows', 'product_name', 'ZZ_TEST Rice');
  return query select * from pg_temp.c('Rice: 20 kg, sales 950 (bill discount shared), cost 600 (batch cost 30/kg), margin 350', '20.000|950.00|600.00|350.00|false', (x->>'quantity') || '|' || (x->>'revenue') || '|' || (x->>'cost') || '|' || (x->>'margin') || '|' || (x->>'cost_missing'));
  x := pg_temp.zrow(j->'rows', 'product_name', 'ZZ_TEST Wheat');
  return query select * from pg_temp.c('Wheat: 30 kg, sales 1,120, cost 750 (batch cost 25/kg), margin 370', '30.000|1120.00|750.00|370.00', (x->>'quantity') || '|' || (x->>'revenue') || '|' || (x->>'cost') || '|' || (x->>'margin'));
  x := pg_temp.zrow(j->'rows', 'product_name', 'ZZ_TEST NoCost');
  return query select * from pg_temp.c('Product whose batch has NO recorded cost: flagged, cost and margin left empty (nothing invented)', 'true|true|true', ((x->>'cost_missing')::boolean)::text || '|' || (x->'margin' = 'null'::jsonb)::text || '|' || (x->'cost' = 'null'::jsonb)::text);
  j := public.report_products(ca, ew1, ew2, 300);
  return query select * from pg_temp.c('Margin, EMPTY range: no rows, zero totals', '0|0.00|0.00|0', jsonb_array_length(j->'rows') || '|' || (j->'totals'->>'revenue') || '|' || (j->'totals'->>'margin') || '|' || (j->'totals'->>'products'));

  ---------------- STOCK VALUATION (batch purchase cost, never selling price) ----------------
  j := public.report_stock_value(ca); x := pg_temp.zrow(j->'rows', 'product_name', 'ZZ_TEST Val');
  return query select * from pg_temp.c('Valuation, product with 2 batches: 10 kg x 20 = 200; the 5 kg with no cost get NO value (selling price 10 is never used)', '200.00|20.00|5.000|15.000', (x->>'value') || '|' || (x->>'avg_cost') || '|' || (x->>'cost_missing_qty') || '|' || (x->>'quantity'));
  return query select * from pg_temp.c('Valuation total equals the sum of quantity x recorded cost over the actual batches', 'true',
    ((j->'totals'->>'value')::numeric = (select round(sum(quantity * purchase_price), 2) from public.product_batches where company_id = ca and quantity > 0 and coalesce(purchase_price, 0) > 0))::text);
  return query select * from pg_temp.c('Valuation counts the products that have stock without a recorded cost (NoCost, Val)', 'true', ((j->'totals'->>'products_cost_missing')::int >= 2)::text);

  ---------------- LOW STOCK (own minimum, else shop default) ----------------
  j := public.report_low_stock(ca);
  return query select * from pg_temp.c('Low stock, default 10: Low1 (5 kg, no minimum) and Low3 (4 < minimum 5) are low; Low2 (8 > 5) is not; Out is out', 'ZZ_TEST Low1,ZZ_TEST Low3,ZZ_TEST Out', pg_temp.names(j->'rows'));
  x := pg_temp.zrow(j->'rows', 'product_name', 'ZZ_TEST Low1');
  return query select * from pg_temp.c('Low1 uses the SHOP DEFAULT (10), Low3 its OWN minimum (5); Out is flagged out', 'true|10|true|5|false|out',
    ((x->>'uses_default')::boolean)::text || '|' || (x->>'threshold')::numeric || '|' || ((x->>'uses_default')::boolean)::text || '|' || (pg_temp.zrow(j->'rows', 'product_name', 'ZZ_TEST Low3')->>'threshold')::numeric || '|' || ((pg_temp.zrow(j->'rows', 'product_name', 'ZZ_TEST Low3')->>'uses_default')::boolean)::text || '|' || (pg_temp.zrow(j->'rows', 'product_name', 'ZZ_TEST Out')->>'status'));
  return query select * from pg_temp.c('Low-stock counts match the rows', 'true', ((j->'counts'->>'low')::int = (select count(*) from jsonb_array_elements(j->'rows') r where r->>'status' = 'low') and (j->'counts'->>'out')::int = (select count(*) from jsonb_array_elements(j->'rows') r where r->>'status' = 'out'))::text);
  reset role; update public.company_settings set low_stock_threshold = 3 where company_id = ca; perform pg_temp.login(ua);
  return query select * from pg_temp.c('Shop default changed to 3: Low1 (5 kg) is no longer low', 'ZZ_TEST Low3,ZZ_TEST Out', pg_temp.names(public.report_low_stock(ca)->'rows'));
  reset role; update public.company_settings set low_stock_threshold = 0 where company_id = ca; perform pg_temp.login(ua);
  return query select * from pg_temp.c('Shop default 0 = no fallback: products without a minimum are never "low" (an empty product is still "out")', 'ZZ_TEST Low3,ZZ_TEST Out', pg_temp.names(public.report_low_stock(ca)->'rows'));
  reset role; delete from public.company_settings where company_id = ca; perform pg_temp.login(ua);
  return query select * from pg_temp.c('No settings row at all: safe default of 10 applies, nothing breaks', 'ZZ_TEST Low1,ZZ_TEST Low3,ZZ_TEST Out|10', pg_temp.names(public.report_low_stock(ca)->'rows') || '|' || (public.report_low_stock(ca)->>'low_default'));
  reset role; if set_a.company_id is not null then insert into public.company_settings select (set_a).*; end if;
  update public.company_settings set low_stock_threshold = 10, expiry_alert_days = 30 where company_id = ca; perform pg_temp.login(ua);

  ---------------- EXPIRY ----------------
  j := public.report_expiry(ca);
  return query select * from pg_temp.c('Expired (before today): EXPD (3 days ago) and EXP2 (1 day ago); the empty batch is not listed', 'EXPD|-3,EXP2|-1',
    (select coalesce(string_agg((r->>'batch_number') || '|' || (r->>'days'), ',' order by r->>'expiry_date'), 'none') from jsonb_array_elements(j->'expired') r where r->>'product_name' like 'ZZ\_TEST%'));
  return query select * from pg_temp.c('Approaching (shop setting = 30 days): SOON (in 10 days) only; FAR (90) and the batch with no expiry are not', 'SOON|10|30',
    (select coalesce(string_agg((r->>'batch_number') || '|' || (r->>'days'), ',' order by r->>'expiry_date'), 'none') from jsonb_array_elements(j->'expiring_soon') r where r->>'product_name' like 'ZZ\_TEST%') || '|' || (j->>'days'));
  return query select * from pg_temp.c('Each row shows product, batch, quantity and expiry date', 'ZZ_TEST ExpSeed|EXPD|10.000|' || (today - 3)::text, (pg_temp.zrow(j->'expired', 'batch_number', 'EXPD')->>'product_name') || '|' || (pg_temp.zrow(j->'expired', 'batch_number', 'EXPD')->>'batch_number') || '|' || (pg_temp.zrow(j->'expired', 'batch_number', 'EXPD')->>'quantity') || '|' || (pg_temp.zrow(j->'expired', 'batch_number', 'EXPD')->>'expiry_date'));
  return query select * from pg_temp.c('Window of 100 days adds FAR (90 days); window of 5 days finds nothing approaching; 0 = only today', 'SOON|10,FAR|90|none|none',
    (select string_agg((r->>'batch_number') || '|' || (r->>'days'), ',' order by r->>'expiry_date') from jsonb_array_elements(public.report_expiry(ca, 100)->'expiring_soon') r where r->>'product_name' like 'ZZ\_TEST%') || '|'
    || (select coalesce(string_agg(r->>'batch_number', ',' ), 'none') from jsonb_array_elements(public.report_expiry(ca, 5)->'expiring_soon') r where r->>'product_name' like 'ZZ\_TEST%') || '|'
    || (select coalesce(string_agg(r->>'batch_number', ',' ), 'none') from jsonb_array_elements(public.report_expiry(ca, 0)->'expiring_soon') r where r->>'product_name' like 'ZZ\_TEST%'));
  return query select * from pg_temp.c('Invalid window refused (negative / over a year)', 'ERR P0001 INVALID_DAYS|ERR P0001 INVALID_DAYS', pg_temp.try(format('select public.report_expiry(%L, -1)', ca)) || '|' || pg_temp.try(format('select public.report_expiry(%L, 400)', ca)));
  return query select * from pg_temp.c('Owner sees cost: EXPD 10 kg x 20 = 200', 'true|20.00|200.00', ((j->>'show_cost')::boolean)::text || '|' || (pg_temp.zrow(j->'expired', 'batch_number', 'EXPD')->>'cost') || '|' || (pg_temp.zrow(j->'expired', 'batch_number', 'EXPD')->>'value'));
  return query select * from pg_temp.c('Expiry counts match the lists', 'true', ((j->'counts'->>'expired')::int = jsonb_array_length(j->'expired') and (j->'counts'->>'expiring_soon')::int = jsonb_array_length(j->'expiring_soon'))::text);

  ---------------- OUTSTANDING (from the payment records) ----------------
  j := public.report_outstanding(ca, 'customer'); x := pg_temp.zrow(j->'rows', 'name', 'ZZ_TEST Ramesh');
  return query select * from pg_temp.c('Customer Ramesh: opening 1,000 + invoices due 600 (200 + 200 + 200) = 1,600 owed', '1000.00|600.00|1600.00', (x->>'opening') || '|' || (x->>'invoices') || '|' || (x->>'outstanding'));
  return query select * from pg_temp.c('Ramesh ageing: 0-30 days 400, 31-60 days 200 (the cancelled invoice and the voided 50 payment do not count)', '400.00|200.00|0.00|0.00', (x->>'d0_30') || '|' || (x->>'d31_60') || '|' || (x->>'d61_90') || '|' || (x->>'d90_plus'));
  return query select * from pg_temp.c('Ramesh matches the existing customer_outstanding() function', 'true', ((x->>'outstanding')::numeric = (select outstanding from public.customer_outstanding(ca, array[cr])))::text);
  x := pg_temp.zrow(j->'rows', 'name', 'ZZ_TEST Advance');
  return query select * from pg_temp.c('Customer with an advance (we owe them 300): shown as -300', '-300.00|0|-300.00', (x->>'opening') || '|' || (x->>'invoices') || '|' || (x->>'outstanding'));
  return query select * from pg_temp.c('Customer totals equal the sum of the rows; invoices agree with the payment records (ledger_mismatch 0)', 'true|0',
    ((j->'totals'->>'outstanding')::numeric = (select sum((r->>'outstanding')::numeric) from jsonb_array_elements(j->'rows') r))::text || '|' || (j->>'ledger_mismatch'));
  j := public.report_outstanding(ca, 'supplier'); x := pg_temp.zrow(j->'rows', 'name', 'ZZ_TEST ABC Agro');
  return query select * from pg_temp.c('Supplier ABC: opening 800 + purchase due 50 (300 - 100 at billing - 150 later) = 850 owed; the 50 is 0-30 days', '800.00|50.00|850.00|50.00', (x->>'opening') || '|' || (x->>'invoices') || '|' || (x->>'outstanding') || '|' || (x->>'d0_30'));
  return query select * from pg_temp.c('Supplier ABC matches the existing supplier_outstanding() function', 'true', ((x->>'outstanding')::numeric = (select outstanding from public.supplier_outstanding(ca, array[sa])))::text);
  return query select * from pg_temp.c('Supplier with an advance (they owe us 200): -200; Report Supplier owes 2,050', '-200.00|2050.00', (pg_temp.zrow(j->'rows', 'name', 'ZZ_TEST XYZ Agro')->>'outstanding') || '|' || (pg_temp.zrow(j->'rows', 'name', 'ZZ_TEST Report Supplier')->>'outstanding'));
  return query select * from pg_temp.c('Supplier totals equal the sum of the rows; ledger_mismatch 0', 'true|0', ((j->'totals'->>'outstanding')::numeric = (select sum((r->>'outstanding')::numeric) from jsonb_array_elements(j->'rows') r))::text || '|' || (j->>'ledger_mismatch'));
  return query select * from pg_temp.c('Unknown kind refused', 'ERR P0001 INVALID_KIND', pg_temp.try(format('select public.report_outstanding(%L, ''staff'')', ca)));

  ---------------- OVERVIEW (built from the reports above, no figure calculated twice) ----------------
  j := public.report_overview(ca, w1, w2);
  return query select * from pg_temp.c('Overview: net sales 2,570, expenses 300, estimated margin 720, purchases 4,100', '2570.00|300.00|720.00|4100.00', (j->'sales'->>'net') || '|' || (j->>'expenses_total') || '|' || (j->'margin'->>'margin') || '|' || (j->'purchases'->>'total'));
  return query select * from pg_temp.c('Overview receivable / payable / stock value / low stock / expired agree with their own reports', 'true|true|true|true|true',
    ((j->>'receivable')::numeric = (public.report_outstanding(ca, 'customer')->'totals'->>'outstanding')::numeric)::text || '|' || ((j->>'payable')::numeric = (public.report_outstanding(ca, 'supplier')->'totals'->>'outstanding')::numeric)::text
    || '|' || ((j->'stock_value'->>'value')::numeric = (public.report_stock_value(ca)->'totals'->>'value')::numeric)::text || '|' || ((j->'low_stock'->>'low')::int = (public.report_low_stock(ca)->'counts'->>'low')::int)::text
    || '|' || ((j->'expiry'->>'expired')::int = (public.report_expiry(ca)->'counts'->>'expired')::int)::text);

  ---------------- ISOLATION: Shop B owner ----------------
  reset role; perform pg_temp.login(ub);
  perform pg_temp.sale(cb, jsonb_build_array(pg_temp.item(pbr, 2)), 100, jsonb_build_object('sale_date', bd + 2));
  j := public.report_sales(cb, w1, w2, 'day');
  return query select * from pg_temp.c('Shop B sees only ITS OWN sale (1 bill, 100), none of Shop A''s 4 bills', '1|100.00', (j->'totals'->>'bills') || '|' || (j->'totals'->>'net'));
  return query select * from pg_temp.c('Shop B margin / purchases / expenses contain nothing of Shop A', '0|0|0.00', (public.report_purchases(cb, w1, w2, 'day')->'totals'->>'bills') || '|' || (public.report_expenses(cb, w1, w2, 'day')->>'count') || '|' || (public.report_expenses(cb, w1, w2, 'day')->>'total'));
  n_denied := 0;
  foreach q in array array[format('select public.report_overview(%L, %L, %L)', ca, w1, w2), format('select public.report_sales(%L, %L, %L)', ca, w1, w2), format('select public.report_purchases(%L, %L, %L)', ca, w1, w2),
      format('select public.report_expenses(%L, %L, %L)', ca, w1, w2), format('select public.report_gst(%L, %L, %L)', ca, w1, w2), format('select public.report_products(%L, %L, %L)', ca, w1, w2),
      format('select public.report_stock_value(%L)', ca), format('select public.report_outstanding(%L, ''customer'')', ca), format('select public.report_outstanding(%L, ''supplier'')', ca),
      format('select public.report_low_stock(%L)', ca), format('select public.report_expiry(%L)', ca)]
  loop if pg_temp.try(q) = 'ERR P0001 NOT_ALLOWED' then n_denied := n_denied + 1; end if; end loop;
  return query select * from pg_temp.c('Shop B is refused on ALL 11 reports of Shop A (financial and stock)', '11', n_denied::text);
  reset role; perform pg_temp.login(ua);
  return query select * from pg_temp.c('Shop A is unchanged by Shop B''s sale (still 4 bills, 2,570)', '4|2570.00', (public.report_sales(ca, w1, w2, 'day')->'totals'->>'bills') || '|' || (public.report_sales(ca, w1, w2, 'day')->'totals'->>'net'));

  ---------------- ROLES: Shop B's user temporarily added to Shop A as a cashier, then a manager ----------------
  reset role; if not had_b_member then insert into public.company_members(company_id, user_id, role) values (ca, ub, 'cashier'); else update public.company_members set role = 'cashier' where company_id = ca and user_id = ub; end if;
  perform pg_temp.login(ub);
  n_denied := 0;
  foreach q in array array[format('select public.report_overview(%L, %L, %L)', ca, w1, w2), format('select public.report_sales(%L, %L, %L)', ca, w1, w2), format('select public.report_purchases(%L, %L, %L)', ca, w1, w2),
      format('select public.report_expenses(%L, %L, %L)', ca, w1, w2), format('select public.report_gst(%L, %L, %L)', ca, w1, w2), format('select public.report_products(%L, %L, %L)', ca, w1, w2),
      format('select public.report_stock_value(%L)', ca), format('select public.report_outstanding(%L, ''customer'')', ca), format('select public.report_outstanding(%L, ''supplier'')', ca)]
  loop if pg_temp.try(q) = 'ERR P0001 NOT_ALLOWED' then n_denied := n_denied + 1; end if; end loop;
  return query select * from pg_temp.c('CASHIER is refused on all 9 financial reports (sales, purchases, expenses, GST, margin, valuation, outstanding x2, overview)', '9', n_denied::text);
  return query select * from pg_temp.c('Cashier CAN run the Low stock report (same rows as the owner)', 'ZZ_TEST Low1,ZZ_TEST Low3,ZZ_TEST Out', pg_temp.names(public.report_low_stock(ca)->'rows'));
  j := public.report_expiry(ca);
  return query select * from pg_temp.c('Cashier CAN run the Expiry report, but cost columns are empty and show_cost is false', 'false|true|true|EXPD', ((j->>'show_cost')::boolean)::text || '|' || (pg_temp.zrow(j->'expired', 'batch_number', 'EXPD')->'cost' = 'null'::jsonb)::text || '|' || (pg_temp.zrow(j->'expired', 'batch_number', 'EXPD')->'value' = 'null'::jsonb)::text || '|' || (pg_temp.zrow(j->'expired', 'batch_number', 'EXPD')->>'batch_number'));
  return query select * from pg_temp.c('Cashier still cannot read expenses or batch cost allocations directly (existing protections kept)', '0|0', (select count(*) from public.expenses where company_id = ca) || '|' || (select count(*) from public.sale_batch_allocations where company_id = ca));
  reset role; update public.company_members set role = 'manager' where company_id = ca and user_id = ub; perform pg_temp.login(ub);
  return query select * from pg_temp.c('MANAGER can run the financial reports (net sales 2,570, expenses 300, margin 720)', '2570.00|300.00|720.00',
    (public.report_overview(ca, w1, w2)->'sales'->>'net') || '|' || (public.report_expenses(ca, w1, w2, 'day')->>'total') || '|' || (public.report_products(ca, w1, w2, 10)->'totals'->>'margin'));
  return query select * from pg_temp.c('Manager sees expiry costs', 'true|20.00', ((public.report_expiry(ca)->>'show_cost')::boolean)::text || '|' || (pg_temp.zrow(public.report_expiry(ca)->'expired', 'batch_number', 'EXPD')->>'cost'));
  reset role; if not had_b_member then delete from public.company_members where company_id = ca and user_id = ub; end if;

  ---------------- NOT LOGGED IN ----------------
  reset role; set local role anon;
  return query select * from pg_temp.c('Anonymous (no login) cannot call any report', '3', (select count(*) from unnest(array[pg_temp.try(format('select public.report_sales(%L, %L, %L)', ca, w1, w2)), pg_temp.try(format('select public.report_low_stock(%L)', ca)), pg_temp.try(format('select public.report_expiry(%L)', ca))]) t where t like 'ERR 42501%')::text);
  reset role;

  ---------------- Existing transaction logic untouched ----------------
  perform pg_temp.login(ua);
  return query select * from pg_temp.c('Invoice payments still equal the payment records (Phase 6 rule)', '0', pg_temp.ledger_ok());
  return query select * from pg_temp.c('Inventory still equals the sum of its batches for every test product (Phase 2 rule)', '0',
    (select count(*) from public.inventory i where i.company_id = ca and i.product_id in (select id from public.products where product_name like 'ZZ\_TEST%') and i.quantity <> coalesce((select sum(quantity) from public.product_batches b where b.product_id = i.product_id and b.company_id = i.company_id), 0))::text);

  ---------------- Clean up everything this test created ----------------
  reset role;
  delete from public.audit_logs where company_id in (ca, cb) and created_at >= now();
  delete from public.sales where notes like 'ZZ\_TEST%';  delete from public.payments where party_name like 'ZZ\_TEST%' or company_id in (ca, cb) and payment_date between bd - 210 and bd + 15;
  delete from public.purchases where notes like 'ZZ\_TEST%';  delete from public.expenses where description like 'ZZ\_TEST%';
  delete from public.inventory_movements where product_id in (select id from public.products where product_name like 'ZZ\_TEST%');
  delete from public.products where product_name like 'ZZ\_TEST%';  delete from public.categories where name like 'ZZ\_TEST%';
  delete from public.customers where customer_name like 'ZZ\_TEST%';  delete from public.suppliers where supplier_name like 'ZZ\_TEST%';
  if ctr_s_a is null then delete from public.sale_counters where company_id = ca; else update public.sale_counters set last_no = ctr_s_a where company_id = ca; end if;
  if ctr_s_b is null then delete from public.sale_counters where company_id = cb; else update public.sale_counters set last_no = ctr_s_b where company_id = cb; end if;
  if ctr_p_a is null then delete from public.purchase_counters where company_id = ca; else update public.purchase_counters set last_no = ctr_p_a where company_id = ca; end if;
  if ctr_p_b is null then delete from public.purchase_counters where company_id = cb; else update public.purchase_counters set last_no = ctr_p_b where company_id = cb; end if;
  delete from public.payment_counters where company_id in (ca, cb);
  if ctr_in_a is not null then insert into public.payment_counters values (ca, 'in', ctr_in_a); end if;   if ctr_out_a is not null then insert into public.payment_counters values (ca, 'out', ctr_out_a); end if;
  if ctr_in_b is not null then insert into public.payment_counters values (cb, 'in', ctr_in_b); end if;   if ctr_out_b is not null then insert into public.payment_counters values (cb, 'out', ctr_out_b); end if;
  if set_a.company_id is not null then update public.company_settings set low_stock_threshold = set_a.low_stock_threshold, expiry_alert_days = set_a.expiry_alert_days where company_id = ca; end if;
  return query select * from pg_temp.c('Cleanup: no test data left; shop settings and memberships restored', '0|0|0|0|0|true|' || had_b_member::text,
    (select count(*) from public.sales where notes like 'ZZ\_TEST%') || '|' || (select count(*) from public.products where product_name like 'ZZ\_TEST%') || '|' || (select count(*) from public.customers where customer_name like 'ZZ\_TEST%')
    || '|' || (select count(*) from public.suppliers where supplier_name like 'ZZ\_TEST%') || '|' || (select count(*) from public.payments where party_name like 'ZZ\_TEST%')
    || '|' || coalesce(((select low_stock_threshold from public.company_settings where company_id = ca) is not distinct from set_a.low_stock_threshold)::text, 'true')
    || '|' || exists (select 1 from public.company_members where company_id = ca and user_id = ub)::text);
  return;
end $$;

select * from pg_temp.step2_test();
