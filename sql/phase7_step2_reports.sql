-- Agro POS — Phase 7, Step 2: Reports & Analytics.
-- READ-ONLY functions only. This file creates NO tables, NO columns, NO indexes, NO policies, and replaces NO existing function.
-- Nothing is written, so no existing data or transaction logic (sales, purchases, payments, expenses, stock) can be affected. Safe to re-run.
-- Tenant column is `company_id` (this app's name for "shop_id"). Every function takes the shop id and filters on it.
--
-- Why functions instead of browser-side totals: the API returns at most 1,000 rows per request, so a busy shop could silently get wrong
-- totals; and a function lets the DATABASE refuse a cashier, instead of only hiding a button.
-- All functions run as the logged-in user (SECURITY INVOKER), so your existing row-level security applies in addition to the shop filter.
--
-- WHO MAY CALL WHAT
--   owner / manager : every report below.
--   any shop member : report_low_stock, report_expiry (quantities and dates only; cost columns are returned to owner/manager only).
--   anyone else (other shop, cashier on a financial report, not logged in): refused with NOT_ALLOWED / permission denied.
--
-- DEFINITIONS (stated once, used by every report)
--   * Only COMPLETED sales/purchases and ACTIVE expenses count. Cancelled sales/purchases, draft purchases, cancelled expenses and voided
--     payments are excluded everywhere (cancelled totals are shown separately where useful).
--   * Net sales = subtotal - bill discount (GST excluded). Net purchases = subtotal - discount + additional charges (GST excluded).
--   * Week = Monday to Sunday; the period label is the Monday.
--   * Low stock: the product's own minimum; if that is 0, the shop default (company_settings.low_stock_threshold, 10 when no settings row);
--     a shop default of 0 means "no default". Quantity 0 is reported as "out".
--   * Expired = expiry date before today (India date). Approaching = from today up to N days ahead (default company_settings.expiry_alert_days, 30).
--   * Outstanding is computed from the PAYMENT RECORDS: invoice total minus its completed payments (+ the opening balance), and compared with the
--     stored balance_due as an integrity check (ledger_mismatch must be 0).
--   * Estimated gross margin = sales (excl. GST, after the bill discount shared across the bill's lines) minus the purchase cost of the batches
--     the stock was actually taken from. Sales lines whose batch has no recorded cost are flagged and EXCLUDED; no cost is ever guessed.
--     It is NOT net profit (expenses and other costs are not deducted).
--   * GST: per sale line, grouped by rate; taxable value is the line value before any bill-level discount (tax is not recomputed after a bill
--     discount, so bill discounts are reported separately). No HSN and no CGST/SGST/IGST split.

do $$ begin
  if to_regclass('public.sales') is null or to_regclass('public.sale_batch_allocations') is null or to_regclass('public.payments') is null
     or to_regclass('public.expenses') is null or to_regprocedure('public.has_role(uuid,text[])') is null
     or to_regprocedure('public.is_member(uuid)') is null or to_regprocedure('public.today_ist()') is null then
    raise exception 'Phase 1-6 not found. Run the earlier SQL files first.';
  end if;
end $$;

-- ---------- permission + range guard ----------
-- p_dated = true: both dates are required, from <= to, and at most ~3 years.
create or replace function public.report_guard(p_company uuid, p_from date default null, p_to date default null, p_dated boolean default false)
returns void language plpgsql stable set search_path = public as $$
begin
  if p_company is null or not public.has_role(p_company, array['owner','manager']) then raise exception 'NOT_ALLOWED'; end if;
  if p_dated then
    if p_from is null or p_to is null or p_from > p_to then raise exception 'INVALID_RANGE'; end if;
    if p_to - p_from > 1100 then raise exception 'RANGE_TOO_LARGE'; end if;
  end if;
end $$;

-- ---------- Sales ----------
create or replace function public.report_sales(p_company uuid, p_from date, p_to date, p_group text default 'day') returns jsonb
language plpgsql stable set search_path = public as $$
declare g text := case p_group when 'month' then 'month' when 'week' then 'week' else 'day' end; r jsonb;
begin
  perform public.report_guard(p_company, p_from, p_to, true);
  select jsonb_build_object(
    'rows', coalesce((select jsonb_agg(jsonb_build_object('period', period, 'bills', bills, 'net', net, 'gst', gst, 'total', total, 'paid', paid, 'due', due) order by period)
        from (select date_trunc(g, sale_date)::date as period, count(*) bills, sum(subtotal - discount) net, sum(tax) gst, sum(grand_total) total, sum(amount_paid) paid, sum(balance_due) due
              from sales where company_id = p_company and status = 'completed' and sale_date between p_from and p_to group by 1) t), '[]'::jsonb),
    'totals', (select jsonb_build_object('bills', count(*), 'net', coalesce(sum(subtotal - discount), 0), 'gst', coalesce(sum(tax), 0), 'total', coalesce(sum(grand_total), 0),
               'paid', coalesce(sum(amount_paid), 0), 'due', coalesce(sum(balance_due), 0)) from sales where company_id = p_company and status = 'completed' and sale_date between p_from and p_to),
    'cancelled', (select jsonb_build_object('bills', count(*), 'total', coalesce(sum(grand_total), 0)) from sales where company_id = p_company and status = 'cancelled' and sale_date between p_from and p_to),
    'by_method', coalesce((select jsonb_agg(jsonb_build_object('method', payment_method, 'bills', bills, 'total', total) order by total desc)
        from (select payment_method, count(*) bills, sum(grand_total) total from sales where company_id = p_company and status = 'completed' and sale_date between p_from and p_to group by 1) m), '[]'::jsonb),
    -- money actually received in the period, from the payment records (at billing and later payments), by method; payments on cancelled sales and voided payments excluded
    'received', jsonb_build_object(
      'total', (select coalesce(sum(p.amount), 0) from payments p join sales s on s.id = p.sale_id and s.company_id = p.company_id
                where p.company_id = p_company and p.direction = 'in' and p.status = 'completed' and s.status = 'completed' and p.payment_date between p_from and p_to),
      'rows', coalesce((select jsonb_agg(jsonb_build_object('method', method, 'payments', n, 'total', total) order by total desc)
                from (select p.payment_method as method, count(*) n, sum(p.amount) total from payments p join sales s on s.id = p.sale_id and s.company_id = p.company_id
                      where p.company_id = p_company and p.direction = 'in' and p.status = 'completed' and s.status = 'completed' and p.payment_date between p_from and p_to group by 1) x), '[]'::jsonb))) into r;
  return r;
end $$;

-- ---------- Purchases ----------
create or replace function public.report_purchases(p_company uuid, p_from date, p_to date, p_group text default 'day') returns jsonb
language plpgsql stable set search_path = public as $$
declare g text := case p_group when 'month' then 'month' when 'week' then 'week' else 'day' end; r jsonb;
begin
  perform public.report_guard(p_company, p_from, p_to, true);
  select jsonb_build_object(
    'rows', coalesce((select jsonb_agg(jsonb_build_object('period', period, 'bills', bills, 'net', net, 'gst', gst, 'total', total, 'paid', paid, 'due', due) order by period)
        from (select date_trunc(g, purchase_date)::date as period, count(*) bills, sum(subtotal - discount + additional_charges) net, sum(tax) gst, sum(grand_total) total, sum(amount_paid) paid, sum(balance_due) due
              from purchases where company_id = p_company and status = 'completed' and purchase_date between p_from and p_to group by 1) t), '[]'::jsonb),
    'totals', (select jsonb_build_object('bills', count(*), 'net', coalesce(sum(subtotal - discount + additional_charges), 0), 'gst', coalesce(sum(tax), 0), 'total', coalesce(sum(grand_total), 0),
               'paid', coalesce(sum(amount_paid), 0), 'due', coalesce(sum(balance_due), 0)) from purchases where company_id = p_company and status = 'completed' and purchase_date between p_from and p_to),
    'cancelled', (select jsonb_build_object('bills', count(*), 'total', coalesce(sum(grand_total), 0)) from purchases where company_id = p_company and status = 'cancelled' and completed_at is not null and purchase_date between p_from and p_to),
    'by_supplier', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'bills', bills, 'total', total, 'paid', paid, 'due', due) order by total desc)
        from (select su.supplier_name as name, count(*) bills, sum(u.grand_total) total, sum(u.amount_paid) paid, sum(u.balance_due) due
              from purchases u join suppliers su on su.id = u.supplier_id and su.company_id = u.company_id
              where u.company_id = p_company and u.status = 'completed' and u.purchase_date between p_from and p_to group by su.id, su.supplier_name order by sum(u.grand_total) desc limit 200) c), '[]'::jsonb)) into r;
  return r;
end $$;

-- ---------- Expenses ----------
create or replace function public.report_expenses(p_company uuid, p_from date, p_to date, p_group text default 'day') returns jsonb
language plpgsql stable set search_path = public as $$
declare g text := case p_group when 'month' then 'month' when 'week' then 'week' else 'day' end; r jsonb;
begin
  perform public.report_guard(p_company, p_from, p_to, true);
  select jsonb_build_object(
    'by_category', coalesce((select jsonb_agg(jsonb_build_object('category', name, 'count', cnt, 'total', total) order by total desc)
        from (select c.name, count(*) cnt, sum(e.amount) total from expenses e join expense_categories c on c.id = e.category_id and c.company_id = e.company_id
              where e.company_id = p_company and e.status = 'active' and e.expense_date between p_from and p_to group by c.id, c.name) t), '[]'::jsonb),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('period', period, 'count', cnt, 'total', total) order by period)
        from (select date_trunc(g, expense_date)::date as period, count(*) cnt, sum(amount) total from expenses
              where company_id = p_company and status = 'active' and expense_date between p_from and p_to group by 1) t), '[]'::jsonb),
    'total', (select coalesce(sum(amount), 0) from expenses where company_id = p_company and status = 'active' and expense_date between p_from and p_to),
    'count', (select count(*) from expenses where company_id = p_company and status = 'active' and expense_date between p_from and p_to),
    'cancelled', (select jsonb_build_object('count', count(*), 'total', coalesce(sum(amount), 0)) from expenses where company_id = p_company and status = 'cancelled' and expense_date between p_from and p_to)) into r;
  return r;
end $$;

-- ---------- Stock valuation: each batch at its OWN recorded purchase price (never the selling price) ----------
-- Stock in a batch with no recorded cost is counted in quantity but given NO value (cost_missing_qty).
create or replace function public.report_stock_value(p_company uuid) returns jsonb
language plpgsql stable set search_path = public as $$
declare r jsonb;
begin
  perform public.report_guard(p_company);
  with b as (select b.product_id, sum(b.quantity) qty, sum(b.quantity) filter (where coalesce(b.purchase_price, 0) > 0) costed_qty,
                    sum(b.quantity * b.purchase_price) filter (where coalesce(b.purchase_price, 0) > 0) value
             from product_batches b where b.company_id = p_company and b.quantity > 0 group by 1)
  select jsonb_build_object(
    'rows', coalesce((select jsonb_agg(jsonb_build_object('product_id', p.id, 'product_name', p.product_name, 'unit', p.unit, 'active', p.is_active, 'quantity', b.qty, 'value', round(coalesce(b.value, 0), 2),
              'avg_cost', case when coalesce(b.costed_qty, 0) > 0 then round(b.value / b.costed_qty, 2) end, 'cost_missing_qty', b.qty - coalesce(b.costed_qty, 0)) order by coalesce(b.value, 0) desc)
              from b join products p on p.id = b.product_id and p.company_id = p_company), '[]'::jsonb),
    'totals', (select jsonb_build_object('value', round(coalesce(sum(value), 0), 2), 'quantity', coalesce(sum(qty), 0), 'products', count(*), 'products_cost_missing', count(*) filter (where qty > coalesce(costed_qty, 0))) from b)) into r;
  return r;
end $$;

-- ---------- Low stock (no costs: any shop member) ----------
create or replace function public.report_low_stock(p_company uuid) returns jsonb
language plpgsql stable set search_path = public as $$
declare low_def int; r jsonb;
begin
  if p_company is null or not public.is_member(p_company) then raise exception 'NOT_ALLOWED'; end if;
  select greatest(low_stock_threshold, 0) into low_def from company_settings where company_id = p_company;
  low_def := coalesce(low_def, 10);
  with x as (select p.id, p.product_name, p.unit, p.minimum_stock, i.quantity,
                    case when p.minimum_stock > 0 then p.minimum_stock else low_def end as threshold, (p.minimum_stock <= 0) as uses_default
             from products p join inventory i on i.product_id = p.id and i.company_id = p.company_id
             where p.company_id = p_company and p.is_active and i.quantity <= (case when p.minimum_stock > 0 then p.minimum_stock else low_def end))
  select jsonb_build_object('low_default', low_def,
    'counts', jsonb_build_object('low', count(*) filter (where quantity > 0), 'out', count(*) filter (where quantity = 0)),
    'rows', coalesce(jsonb_agg(jsonb_build_object('product_id', id, 'product_name', product_name, 'unit', unit, 'quantity', quantity, 'minimum', minimum_stock, 'threshold', threshold,
              'uses_default', uses_default, 'status', case when quantity = 0 then 'out' else 'low' end) order by (quantity = 0) desc, quantity, product_name), '[]'::jsonb)) into r from x;
  return r;
end $$;

-- ---------- Expiry (quantities and dates: any shop member; cost only for owner/manager) ----------
create or replace function public.report_expiry(p_company uuid, p_days int default null) returns jsonb
language plpgsql stable set search_path = public as $$
declare d int; today date := public.today_ist(); can_cost boolean; r jsonb;
begin
  if p_company is null or not public.is_member(p_company) then raise exception 'NOT_ALLOWED'; end if;
  can_cost := public.has_role(p_company, array['owner','manager']);
  d := coalesce(p_days, (select expiry_alert_days from company_settings where company_id = p_company), 30);
  if d < 0 or d > 365 then raise exception 'INVALID_DAYS'; end if;
  with b as (select p.id pid, p.product_name, p.unit, bt.id bid, bt.batch_number, bt.expiry_date, bt.quantity, bt.purchase_price
             from product_batches bt join products p on p.id = bt.product_id and p.company_id = bt.company_id
             where bt.company_id = p_company and bt.quantity > 0 and bt.expiry_date is not null and bt.expiry_date <= today + d),
  e as (select b.*, case when expiry_date < today then 'expired' else 'soon' end as kind from b)
  select jsonb_build_object('days', d, 'show_cost', can_cost,
    'counts', jsonb_build_object('expired', count(*) filter (where kind = 'expired'), 'expiring_soon', count(*) filter (where kind = 'soon')),
    'expired', coalesce(jsonb_agg(jsonb_build_object('product_id', pid, 'product_name', product_name, 'unit', unit, 'batch_id', bid, 'batch_number', batch_number, 'expiry_date', expiry_date,
              'days', expiry_date - today, 'quantity', quantity, 'cost', case when can_cost then purchase_price end, 'value', case when can_cost then quantity * coalesce(purchase_price, 0) end)
              order by expiry_date, product_name) filter (where kind = 'expired'), '[]'::jsonb),
    'expiring_soon', coalesce(jsonb_agg(jsonb_build_object('product_id', pid, 'product_name', product_name, 'unit', unit, 'batch_id', bid, 'batch_number', batch_number, 'expiry_date', expiry_date,
              'days', expiry_date - today, 'quantity', quantity, 'cost', case when can_cost then purchase_price end, 'value', case when can_cost then quantity * coalesce(purchase_price, 0) end)
              order by expiry_date, product_name) filter (where kind = 'soon'), '[]'::jsonb)) into r from e;
  return r;
end $$;

-- ---------- Outstanding, from the payment records ----------
create or replace function public.report_outstanding(p_company uuid, p_kind text) returns jsonb
language plpgsql stable set search_path = public as $$
declare r jsonb; today date := public.today_ist();
begin
  perform public.report_guard(p_company);
  if p_kind = 'customer' then
    with inv as (select s.customer_id id, s.sale_date d, s.balance_due stored,
                        s.grand_total - coalesce((select sum(p.amount) from payments p where p.sale_id = s.id and p.company_id = s.company_id and p.status = 'completed'), 0) as due
                 from sales s where s.company_id = p_company and s.status = 'completed' and s.customer_id is not null),
    ag as (select id, sum(due) invoices, sum(due) filter (where due > 0 and today - d <= 30) b1, sum(due) filter (where due > 0 and today - d between 31 and 60) b2,
                  sum(due) filter (where due > 0 and today - d between 61 and 90) b3, sum(due) filter (where due > 0 and today - d > 90) b4 from inv group by id),
    t as (select c.id, c.customer_name as name, c.phone, case when c.balance_type = 'debit' then c.opening_balance else -c.opening_balance end as opening,
                 coalesce(ag.invoices, 0) invoices, coalesce(ag.b1, 0) b1, coalesce(ag.b2, 0) b2, coalesce(ag.b3, 0) b3, coalesce(ag.b4, 0) b4
          from customers c left join ag on ag.id = c.id where c.company_id = p_company),
    shown as (select *, opening + invoices as outstanding from t where opening + invoices <> 0)
    select jsonb_build_object('rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'phone', phone, 'opening', opening, 'invoices', invoices, 'outstanding', outstanding,
                'd0_30', b1, 'd31_60', b2, 'd61_90', b3, 'd90_plus', b4) order by outstanding desc, name) from shown), '[]'::jsonb),
           'totals', (select jsonb_build_object('outstanding', coalesce(sum(outstanding), 0), 'opening', coalesce(sum(opening), 0), 'invoices', coalesce(sum(invoices), 0), 'parties', count(*)) from shown),
           'ledger_mismatch', (select count(*) from inv where round(due, 2) <> round(stored, 2))) into r;
  elsif p_kind = 'supplier' then
    with inv as (select u.supplier_id id, u.purchase_date d, u.balance_due stored,
                        u.grand_total - coalesce((select sum(p.amount) from payments p where p.purchase_id = u.id and p.company_id = u.company_id and p.status = 'completed'), 0) as due
                 from purchases u where u.company_id = p_company and u.status = 'completed'),
    ag as (select id, sum(due) invoices, sum(due) filter (where due > 0 and today - d <= 30) b1, sum(due) filter (where due > 0 and today - d between 31 and 60) b2,
                  sum(due) filter (where due > 0 and today - d between 61 and 90) b3, sum(due) filter (where due > 0 and today - d > 90) b4 from inv group by id),
    t as (select s.id, s.supplier_name as name, s.phone, case when s.balance_type = 'credit' then s.opening_balance else -s.opening_balance end as opening,
                 coalesce(ag.invoices, 0) invoices, coalesce(ag.b1, 0) b1, coalesce(ag.b2, 0) b2, coalesce(ag.b3, 0) b3, coalesce(ag.b4, 0) b4
          from suppliers s left join ag on ag.id = s.id where s.company_id = p_company),
    shown as (select *, opening + invoices as outstanding from t where opening + invoices <> 0)
    select jsonb_build_object('rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'phone', phone, 'opening', opening, 'invoices', invoices, 'outstanding', outstanding,
                'd0_30', b1, 'd31_60', b2, 'd61_90', b3, 'd90_plus', b4) order by outstanding desc, name) from shown), '[]'::jsonb),
           'totals', (select jsonb_build_object('outstanding', coalesce(sum(outstanding), 0), 'opening', coalesce(sum(opening), 0), 'invoices', coalesce(sum(invoices), 0), 'parties', count(*)) from shown),
           'ledger_mismatch', (select count(*) from inv where round(due, 2) <> round(stored, 2))) into r;
  else raise exception 'INVALID_KIND'; end if;
  return r;
end $$;

-- ---------- GST summary (sales only, by rate) ----------
create or replace function public.report_gst(p_company uuid, p_from date, p_to date) returns jsonb
language plpgsql stable set search_path = public as $$
declare r jsonb;
begin
  perform public.report_guard(p_company, p_from, p_to, true);
  select jsonb_build_object(
    'rows', coalesce((select jsonb_agg(jsonb_build_object('rate', rate, 'lines', lines, 'taxable', taxable, 'tax', tax) order by rate)
        from (select i.tax_rate as rate, count(*) lines, sum(i.line_total - i.tax) taxable, sum(i.tax) tax from sale_items i join sales s on s.id = i.sale_id and s.company_id = i.company_id
              where i.company_id = p_company and s.status = 'completed' and s.sale_date between p_from and p_to group by 1) t), '[]'::jsonb),
    'totals', (select jsonb_build_object('taxable', coalesce(sum(i.line_total - i.tax), 0), 'tax', coalesce(sum(i.tax), 0), 'bills', count(distinct s.id))
               from sale_items i join sales s on s.id = i.sale_id and s.company_id = i.company_id where i.company_id = p_company and s.status = 'completed' and s.sale_date between p_from and p_to),
    'bill_discount', (select coalesce(sum(discount), 0) from sales where company_id = p_company and status = 'completed' and sale_date between p_from and p_to)) into r;
  return r;
end $$;

-- ---------- Estimated gross margin by product (batch cost; owner/manager) ----------
create or replace function public.report_products(p_company uuid, p_from date, p_to date, p_limit int default 300) returns jsonb
language plpgsql stable set search_path = public as $$
declare r jsonb;
begin
  perform public.report_guard(p_company, p_from, p_to, true);
  with s as (select id, subtotal, discount from sales where company_id = p_company and status = 'completed' and sale_date between p_from and p_to),
  it as (select i.sale_id, i.product_id, sum(i.quantity) qty, sum(i.line_total - i.tax) taxable from sale_items i join s on s.id = i.sale_id where i.company_id = p_company group by 1, 2),
  al as (select a.sale_id, a.product_id, sum(a.quantity) aq, sum(a.quantity * coalesce(b.purchase_price, 0)) cost,
                sum(case when coalesce(b.purchase_price, 0) = 0 then a.quantity else 0 end) miss
         from sale_batch_allocations a join s on s.id = a.sale_id join product_batches b on b.id = a.batch_id and b.company_id = a.company_id where a.company_id = p_company group by 1, 2),
  x as (select it.product_id, it.qty, it.taxable - case when s.subtotal > 0 then s.discount * it.taxable / s.subtotal else 0 end as revenue,
               coalesce(al.cost, 0) as cost, coalesce(al.miss, 0) + greatest(it.qty - coalesce(al.aq, 0), 0) as miss
        from it join s on s.id = it.sale_id left join al on al.sale_id = it.sale_id and al.product_id = it.product_id),
  pr as (select x.product_id, sum(x.qty) as qty, round(sum(x.revenue), 2) as revenue, round(sum(x.cost), 2) as cost, sum(x.miss) as miss from x group by 1)
  select jsonb_build_object(
    'rows', coalesce((select jsonb_agg(jsonb_build_object('product_id', pr.product_id, 'product_name', p.product_name, 'unit', p.unit, 'quantity', pr.qty, 'revenue', pr.revenue,
              'cost', case when pr.miss = 0 then pr.cost end, 'margin', case when pr.miss = 0 then pr.revenue - pr.cost end,
              'margin_pct', case when pr.miss = 0 and pr.revenue > 0 then round((pr.revenue - pr.cost) / pr.revenue * 100, 1) end, 'cost_missing', pr.miss > 0) order by pr.revenue desc)
              from (select * from pr order by revenue desc limit greatest(p_limit, 1)) pr join products p on p.id = pr.product_id and p.company_id = p_company), '[]'::jsonb),
    'totals', (select jsonb_build_object('revenue', coalesce(sum(revenue), 0), 'revenue_costed', coalesce(sum(revenue) filter (where miss = 0), 0),
              'cost', coalesce(sum(cost) filter (where miss = 0), 0), 'margin', coalesce(sum(revenue - cost) filter (where miss = 0), 0),
              'revenue_uncosted', coalesce(sum(revenue) filter (where miss > 0), 0), 'products', count(*), 'products_cost_missing', count(*) filter (where miss > 0)) from pr)) into r;
  return r;
end $$;

-- ---------- Overview: built from the reports above so no figure is calculated twice ----------
create or replace function public.report_overview(p_company uuid, p_from date, p_to date) returns jsonb
language plpgsql stable set search_path = public as $$
declare sl jsonb; pu jsonb; ex jsonb; pr jsonb; sv jsonb; lo jsonb; xp jsonb; rc jsonb; py jsonb;
begin
  perform public.report_guard(p_company, p_from, p_to, true);
  sl := public.report_sales(p_company, p_from, p_to, 'month'); pu := public.report_purchases(p_company, p_from, p_to, 'month'); ex := public.report_expenses(p_company, p_from, p_to, 'month');
  pr := public.report_products(p_company, p_from, p_to, 1); sv := public.report_stock_value(p_company); lo := public.report_low_stock(p_company); xp := public.report_expiry(p_company);
  rc := public.report_outstanding(p_company, 'customer'); py := public.report_outstanding(p_company, 'supplier');
  return jsonb_build_object('sales', sl->'totals', 'received', sl->'received'->'total', 'purchases', pu->'totals', 'expenses_total', ex->'total', 'margin', pr->'totals',
    'stock_value', sv->'totals', 'low_stock', lo->'counts', 'expiry', xp->'counts', 'expiry_days', xp->'days',
    'receivable', rc->'totals'->'outstanding', 'payable', py->'totals'->'outstanding', 'ledger_mismatch', ((rc->>'ledger_mismatch')::int + (py->>'ledger_mismatch')::int));
end $$;

-- ---------- Privileges: logged-in users only (the checks above decide who gets data) ----------
revoke all on function public.report_guard(uuid, date, date, boolean), public.report_sales(uuid, date, date, text), public.report_purchases(uuid, date, date, text),
  public.report_expenses(uuid, date, date, text), public.report_stock_value(uuid), public.report_low_stock(uuid), public.report_expiry(uuid, int),
  public.report_outstanding(uuid, text), public.report_gst(uuid, date, date), public.report_products(uuid, date, date, int), public.report_overview(uuid, date, date) from public, anon;
grant execute on function public.report_guard(uuid, date, date, boolean), public.report_sales(uuid, date, date, text), public.report_purchases(uuid, date, date, text),
  public.report_expenses(uuid, date, date, text), public.report_stock_value(uuid), public.report_low_stock(uuid), public.report_expiry(uuid, int),
  public.report_outstanding(uuid, text), public.report_gst(uuid, date, date), public.report_products(uuid, date, date, int), public.report_overview(uuid, date, date) to authenticated;
