-- Agro POS — Phase 5: sales & billing.
-- ADDITIVE ONLY. Creates new tables/functions; never alters or drops Phase 1-4 objects. Safe to re-run.
-- Reuses: companies, customers, products, inventory, product_batches, inventory_movements, audit_logs,
--         company_settings(invoice_prefix), is_member(), has_role(), touch_updated_at().
-- Tenant column is `company_id` (this app's name for "shop_id").
--
-- STOCK SOURCE OF TRUTH (found by auditing Phase 4): inventory.quantity per (company, product), kept equal to the sum of
-- product_batches.quantity, with every change logged in inventory_movements. Sales use exactly that, and the movement types
-- 'sale' / 'sale_return' that Phase 2 already allows. No new inventory structure is created.
--
-- DESIGN
--  * sales / sale_items / sale_batch_allocations are READ-ONLY for clients. All writes go through create_sale / update_sale /
--    cancel_sale: ONE transaction = header + items + stock (batches, inventory, movements) + audit. Any error rolls back everything.
--  * A sale takes stock from the batch that expires first (FEFO) and never from expired batches. sale_batch_allocations records
--    exactly which batch gave how much, so an edit/cancel returns stock to the right batches and cannot restore more than was taken.
--  * EDITING applies only the NET change per product (20 -> 15 returns 5; 20 -> 30 takes 10 more, if available).
--  * Totals are computed in the database (numeric, never floats). Same rule as purchases:
--      line taxable = round(qty*price,2) - line discount ; line tax = round(taxable*rate/100,2) (rate = product GST % at sale time,
--      kept on the line); subtotal = sum(taxable); grand_total = subtotal - bill discount + tax. Prices are tax-exclusive.
--  * Product name/unit/SKU are copied onto each sale line so old invoices never change when a product is renamed or repriced.
--  * Payment: cash | upi | card | credit. payment_status is derived: paid | partial | pending. Any unpaid balance REQUIRES a
--    saved customer (walk-in customers must pay in full), enforced by a CHECK. Amount paid can never exceed the total.
--  * Customer balance is DERIVED (never stored): signed opening balance + sum(balance_due of COMPLETED sales).
--    customers: balance_type 'debit' = customer owes the shop (+), 'credit' = shop owes customer (-). Positive = customer owes you.
--  * Roles: owner/manager/cashier can create a sale; only owner/manager can edit or cancel. Everyone in the shop can read.

do $$ begin
  if to_regclass('public.customers') is null or to_regclass('public.products') is null or to_regclass('public.inventory') is null
     or to_regclass('public.product_batches') is null or to_regclass('public.inventory_movements') is null
     or to_regclass('public.audit_logs') is null or to_regclass('public.company_settings') is null
     or to_regprocedure('public.is_member(uuid)') is null or to_regprocedure('public.has_role(uuid,text[])') is null
     or to_regprocedure('public.touch_updated_at()') is null then
    raise exception 'Phase 1-4 not found. Run the earlier SQL files first.';
  end if;
end $$;

-- India shop-floor "today": the server runs in UTC, but expiry and sale dates should follow the shop's calendar day.
create or replace function public.today_ist() returns date language sql stable as $$ select (now() at time zone 'Asia/Kolkata')::date $$;

-- ---------- Tables ----------
create table if not exists public.sale_counters (company_id uuid primary key references public.companies(id) on delete cascade, last_no integer not null default 0);

create table if not exists public.sales (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  invoice_no text not null check (char_length(invoice_no) between 3 and 40),
  customer_id uuid,
  customer_name text not null default 'Walk-in Customer' check (char_length(btrim(customer_name)) between 1 and 150),
  customer_phone text check (customer_phone is null or customer_phone ~ '^\+?[0-9]{10,13}$'),
  sale_date date not null default current_date,
  subtotal numeric(14,2) not null default 0 check (subtotal >= 0),
  discount numeric(14,2) not null default 0 check (discount >= 0),
  tax numeric(14,2) not null default 0 check (tax >= 0),
  grand_total numeric(14,2) not null default 0 check (grand_total >= 0),
  payment_method text not null default 'cash' check (payment_method in ('cash','upi','card','credit')),
  amount_paid numeric(14,2) not null default 0 check (amount_paid >= 0),
  balance_due numeric(14,2) not null default 0 check (balance_due >= 0),
  payment_status text not null default 'paid' check (payment_status in ('paid','partial','pending')),
  notes text check (notes is null or char_length(notes) <= 1000),
  status text not null default 'completed' check (status in ('completed','cancelled')),
  cancel_reason text check (cancel_reason is null or char_length(cancel_reason) <= 500),
  cancelled_by uuid references auth.users(id),
  cancelled_at timestamptz,
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, company_id),
  unique (company_id, invoice_no),
  foreign key (customer_id, company_id) references public.customers(id, company_id),   -- customer must be in the same company
  check (grand_total = subtotal - discount + tax),
  check (amount_paid <= grand_total),
  check (balance_due = grand_total - amount_paid),
  check (customer_id is not null or balance_due = 0));                                -- unpaid balance needs a saved customer

create table if not exists public.sale_items (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null,
  company_id uuid not null references public.companies(id) on delete cascade,
  line_no integer not null check (line_no > 0),
  product_id uuid not null,
  product_name_snapshot text not null,
  unit_snapshot text not null,
  sku_snapshot text,
  quantity numeric(14,3) not null check (quantity > 0),
  unit_price numeric(12,2) not null check (unit_price >= 0),
  discount numeric(12,2) not null default 0 check (discount >= 0),
  tax_rate numeric(5,2) not null default 0 check (tax_rate between 0 and 100),
  tax numeric(12,2) not null default 0 check (tax >= 0),
  line_total numeric(14,2) not null check (line_total >= 0),
  created_at timestamptz not null default now(),
  unique (sale_id, line_no),
  foreign key (sale_id, company_id) references public.sales(id, company_id) on delete cascade,
  foreign key (product_id, company_id) references public.products(id, company_id));

-- What a COMPLETED sale currently holds out of each batch. Empty for a cancelled sale (stock was handed back).
create table if not exists public.sale_batch_allocations (
  id uuid primary key default gen_random_uuid(),
  seq bigint generated always as identity,
  sale_id uuid not null,
  company_id uuid not null references public.companies(id) on delete cascade,
  product_id uuid not null,
  batch_id uuid not null,
  quantity numeric(14,3) not null check (quantity > 0),
  unique (sale_id, product_id, batch_id),
  foreign key (sale_id, company_id) references public.sales(id, company_id) on delete cascade,
  foreign key (batch_id, company_id) references public.product_batches(id, company_id),
  foreign key (product_id, company_id) references public.products(id, company_id));

-- ---------- Indexes ----------
create index if not exists sales_company_date_idx on public.sales(company_id, sale_date desc, created_at desc);
create index if not exists sales_company_status_idx on public.sales(company_id, status);
create index if not exists sales_company_customer_idx on public.sales(company_id, customer_id) where customer_id is not null;
create index if not exists sales_company_pending_idx on public.sales(company_id) where status = 'completed' and balance_due > 0;
create index if not exists sale_items_sale_idx on public.sale_items(sale_id);
create index if not exists sale_items_company_product_idx on public.sale_items(company_id, product_id);
create index if not exists sale_alloc_sale_idx on public.sale_batch_allocations(sale_id, product_id, seq);
create index if not exists sale_alloc_batch_idx on public.sale_batch_allocations(batch_id);

drop trigger if exists sales_touch on public.sales;
create trigger sales_touch before update on public.sales for each row execute function public.touch_updated_at();

-- ---------- RLS: members read; nobody writes directly ----------
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;
alter table public.sale_batch_allocations enable row level security;
alter table public.sale_counters enable row level security;           -- no policies = no access

revoke all on public.sales, public.sale_items, public.sale_batch_allocations, public.sale_counters from anon, authenticated;
grant select on public.sales, public.sale_items to authenticated;
grant select on public.sale_batch_allocations to authenticated;

drop policy if exists sales_select on public.sales;
create policy sales_select on public.sales for select to authenticated using (public.is_member(company_id));
drop policy if exists sale_items_select on public.sale_items;
create policy sale_items_select on public.sale_items for select to authenticated using (public.is_member(company_id));
drop policy if exists sale_alloc_select on public.sale_batch_allocations;
create policy sale_alloc_select on public.sale_batch_allocations for select to authenticated using (public.has_role(company_id, array['owner','manager']));

-- ---------- Internal: take stock for a sale (soonest-expiring non-expired batch first) ----------
-- Lock order matches Phase 2/4: batch rows first, then the inventory row. Raises INSUFFICIENT_STOCK (detail 'productid:available').
create or replace function public.sale_stock_take(p_cid uuid, p_sale uuid, p_product uuid, p_qty numeric, p_ref text)
returns void language plpgsql set search_path = public as $$
declare r record; need numeric := p_qty; take numeric; inv inventory; running numeric;
begin
  if p_qty is null or p_qty <= 0 then return; end if;
  perform 1 from product_batches where company_id = p_cid and product_id = p_product order by id for update;
  select * into inv from inventory where company_id = p_cid and product_id = p_product for update;
  if not found then raise exception 'INSUFFICIENT_STOCK' using detail = p_product::text || ':0'; end if;
  running := inv.quantity;
  for r in select id, quantity from product_batches
           where company_id = p_cid and product_id = p_product and quantity > 0 and (expiry_date is null or expiry_date >= public.today_ist())
           order by expiry_date nulls last, created_at, id loop
    exit when need <= 0;
    take := least(r.quantity, need);
    update product_batches set quantity = quantity - take where id = r.id;
    insert into sale_batch_allocations(sale_id, company_id, product_id, batch_id, quantity) values (p_sale, p_cid, p_product, r.id, take)
      on conflict (sale_id, product_id, batch_id) do update set quantity = sale_batch_allocations.quantity + excluded.quantity;
    insert into inventory_movements(company_id, product_id, batch_id, movement_type, quantity, previous_quantity, new_quantity, reference_type, reference_id, notes)
      values (p_cid, p_product, r.id, 'sale', -take, running, running - take, 'sale', p_ref, 'Sale');
    running := running - take; need := need - take;
  end loop;
  if need > 0 then raise exception 'INSUFFICIENT_STOCK' using detail = p_product::text || ':' || (p_qty - need)::text; end if;
  update inventory set quantity = running, updated_at = now() where id = inv.id;
end $$;

-- ---------- Internal: give stock back to the batches this sale took it from (most recent allocation first) ----------
create or replace function public.sale_stock_return(p_cid uuid, p_sale uuid, p_product uuid, p_qty numeric, p_ref text, p_note text)
returns void language plpgsql set search_path = public as $$
declare r record; need numeric := p_qty; give numeric; inv inventory; running numeric;
begin
  if p_qty is null or p_qty <= 0 then return; end if;
  perform 1 from product_batches where company_id = p_cid and product_id = p_product order by id for update;
  select * into inv from inventory where company_id = p_cid and product_id = p_product for update;
  if not found then raise exception 'ALLOCATION_MISMATCH'; end if;
  running := inv.quantity;
  for r in select id, batch_id, quantity from sale_batch_allocations where sale_id = p_sale and product_id = p_product order by seq desc loop
    exit when need <= 0;
    give := least(r.quantity, need);
    update product_batches set quantity = quantity + give where id = r.batch_id;
    if give = r.quantity then delete from sale_batch_allocations where id = r.id;
    else update sale_batch_allocations set quantity = quantity - give where id = r.id; end if;
    insert into inventory_movements(company_id, product_id, batch_id, movement_type, quantity, previous_quantity, new_quantity, reference_type, reference_id, notes)
      values (p_cid, p_product, r.batch_id, 'sale_return', give, running, running + give, 'sale', p_ref, p_note);
    running := running + give; need := need - give;
  end loop;
  if need > 0 then raise exception 'ALLOCATION_MISMATCH'; end if;   -- would mean returning more than the sale ever took
  update inventory set quantity = running, updated_at = now() where id = inv.id;
end $$;

-- ---------- Internal: create (p_id null) or edit one sale ----------
-- p = { company_id (create only), customer_id | customer_name + customer_phone (walk-in), sale_date, discount, payment_method,
--       amount_paid, notes, items: [{product_id, quantity, unit_price, discount}] }
create or replace function public.sale_upsert(p_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  cid uuid; sl sales; cust customers; prod products; it jsonb; idx int := 0; lines jsonb := '[]'::jsonb; v_old jsonb := '[]'::jsonb;
  qty numeric; price numeric; idisc numeric; rate numeric; gross numeric; taxable numeric; tx numeric; lt numeric; old_rate numeric;
  v_sub numeric := 0; v_tax numeric := 0; v_disc numeric; v_paid numeric; v_grand numeric; v_pay text; v_method text;
  v_date date; v_notes text; v_cname text; v_cphone text; v_cid uuid; n int; v_prefix text; v_no text; d record; v_action text;
begin
  if p_id is null then cid := nullif(p->>'company_id','')::uuid;
  else
    select * into sl from sales where id = p_id for update;
    cid := sl.company_id;
  end if;
  -- Creating: owner, manager or cashier. Editing: owner or manager. Unknown id / other shop's id both answer NOT_ALLOWED.
  if cid is null or not has_role(cid, case when p_id is null then array['owner','manager','cashier'] else array['owner','manager'] end) then
    raise exception 'NOT_ALLOWED'; end if;
  if p_id is not null and sl.status = 'cancelled' then raise exception 'SALE_CANCELLED'; end if;

  v_cid := nullif(p->>'customer_id','')::uuid;
  if v_cid is not null then
    select * into cust from customers where id = v_cid and company_id = cid;
    if not found then raise exception 'CUSTOMER_NOT_FOUND'; end if;
    if not cust.is_active and (p_id is null or sl.customer_id is distinct from v_cid) then raise exception 'CUSTOMER_INACTIVE'; end if;
    v_cname := cust.customer_name; v_cphone := cust.phone;
  else
    v_cname := coalesce(nullif(btrim(p->>'customer_name'), ''), 'Walk-in Customer');
    v_cphone := nullif(regexp_replace(coalesce(p->>'customer_phone', ''), '[\s()-]', '', 'g'), '');
  end if;

  v_date := coalesce(nullif(p->>'sale_date','')::date, public.today_ist());
  if v_date > public.today_ist() + 1 or v_date < date '2000-01-01' then raise exception 'INVALID_DATE'; end if;
  v_method := coalesce(nullif(p->>'payment_method',''), 'cash');
  if v_method not in ('cash','upi','card','credit') then raise exception 'INVALID_PAYMENT_METHOD'; end if;
  v_notes := nullif(btrim(p->>'notes'), '');
  v_disc := coalesce(nullif(p->>'discount','')::numeric, 0);
  v_paid := coalesce(nullif(p->>'amount_paid','')::numeric, 0);
  if v_disc < 0 or v_paid < 0 or v_disc <> round(v_disc,2) or v_paid <> round(v_paid,2) then raise exception 'INVALID_AMOUNT'; end if;

  if jsonb_typeof(p->'items') is distinct from 'array' or jsonb_array_length(p->'items') = 0 then raise exception 'NO_ITEMS'; end if;
  if jsonb_array_length(p->'items') > 200 then raise exception 'TOO_MANY_ITEMS'; end if;

  for it in select value from jsonb_array_elements(p->'items') loop
    idx := idx + 1;
    qty   := (it->>'quantity')::numeric;
    price := coalesce(nullif(it->>'unit_price','')::numeric, 0);
    idisc := coalesce(nullif(it->>'discount','')::numeric, 0);
    if qty is null or qty <= 0 or qty <> round(qty,3) then raise exception 'INVALID_QUANTITY'; end if;
    if price < 0 or price <> round(price,2) or idisc < 0 or idisc <> round(idisc,2) then raise exception 'INVALID_AMOUNT'; end if;
    select * into prod from products where id = nullif(it->>'product_id','')::uuid and company_id = cid;
    if not found then raise exception 'PRODUCT_NOT_FOUND'; end if;
    if not prod.is_active and not (p_id is not null and exists (select 1 from sale_items where sale_id = p_id and product_id = prod.id)) then
      raise exception 'PRODUCT_INACTIVE'; end if;
    -- GST rate: a product already on this sale keeps the rate it was sold at; otherwise the product's current rate (never from the browser).
    old_rate := null;
    if p_id is not null then select tax_rate into old_rate from sale_items where sale_id = p_id and product_id = prod.id limit 1; end if;
    rate := coalesce(old_rate, prod.tax_rate);
    if rate < 0 or rate > 100 then raise exception 'INVALID_TAX_RATE'; end if;
    rate := round(rate, 2);
    gross := round(qty * price, 2);
    if idisc > gross then raise exception 'DISCOUNT_TOO_HIGH'; end if;
    taxable := gross - idisc; tx := round(taxable * rate / 100, 2); lt := taxable + tx;
    v_sub := v_sub + taxable; v_tax := v_tax + tx;
    lines := lines || jsonb_build_object('line_no', idx, 'product_id', prod.id, 'name', prod.product_name, 'unit', prod.unit, 'sku', coalesce(prod.sku, prod.product_code),
      'quantity', qty, 'unit_price', price, 'discount', idisc, 'tax_rate', rate, 'tax', tx, 'line_total', lt);
  end loop;

  if v_disc > v_sub then raise exception 'DISCOUNT_TOO_HIGH'; end if;
  v_grand := v_sub - v_disc + v_tax;
  if v_paid > v_grand then raise exception 'PAID_EXCEEDS_TOTAL'; end if;
  if v_grand - v_paid > 0 and v_cid is null then raise exception 'CUSTOMER_REQUIRED_FOR_CREDIT'; end if;
  v_pay := case when v_paid >= v_grand then 'paid' when v_paid = 0 then 'pending' else 'partial' end;

  if p_id is null then
    insert into sale_counters(company_id, last_no) values (cid, 1)
      on conflict (company_id) do update set last_no = sale_counters.last_no + 1 returning last_no into n;
    select left(regexp_replace(coalesce(invoice_prefix, ''), '[^A-Za-z0-9]', '', 'g'), 10) into v_prefix from company_settings where company_id = cid;
    v_no := coalesce(nullif(v_prefix, ''), 'INV') || '-' || lpad(n::text, 6, '0');
    insert into sales(company_id, invoice_no, customer_id, customer_name, customer_phone, sale_date, subtotal, discount, tax, grand_total,
        payment_method, amount_paid, balance_due, payment_status, notes)
      values (cid, v_no, v_cid, v_cname, v_cphone, v_date, v_sub, v_disc, v_tax, v_grand, v_method, v_paid, v_grand - v_paid, v_pay, v_notes)
      returning * into sl;
    v_action := 'sale_created';
  else
    v_old := coalesce((select jsonb_agg(jsonb_build_object('product_id', product_id, 'q', q))
                       from (select product_id, sum(quantity) q from sale_batch_allocations where sale_id = p_id group by 1) s), '[]'::jsonb);
    delete from sale_items where sale_id = p_id;
    update sales set customer_id = v_cid, customer_name = v_cname, customer_phone = v_cphone, sale_date = v_date, subtotal = v_sub, discount = v_disc,
        tax = v_tax, grand_total = v_grand, payment_method = v_method, amount_paid = v_paid, balance_due = v_grand - v_paid, payment_status = v_pay, notes = v_notes
      where id = p_id returning * into sl;
    v_action := 'sale_updated';
  end if;

  insert into sale_items(sale_id, company_id, line_no, product_id, product_name_snapshot, unit_snapshot, sku_snapshot, quantity, unit_price, discount, tax_rate, tax, line_total)
    select sl.id, cid, l.line_no, l.product_id, l.name, l.unit, l.sku, l.quantity, l.unit_price, l.discount, l.tax_rate, l.tax, l.line_total
    from jsonb_to_recordset(lines) as l(line_no int, product_id uuid, name text, unit text, sku text, quantity numeric, unit_price numeric, discount numeric, tax_rate numeric, tax numeric, line_total numeric);

  -- Stock: only the NET change per product (new total - what the sale already holds). Products in ascending id order (stable lock order).
  for d in
    select coalesce(nw.product_id, o.product_id) as pid, coalesce(nw.q, 0) - coalesce(o.q, 0) as delta
    from (select product_id, sum(quantity) as q from sale_items where sale_id = sl.id group by 1) nw
    full join (select product_id, q from jsonb_to_recordset(v_old) as x(product_id uuid, q numeric)) o on o.product_id = nw.product_id
    where coalesce(nw.q, 0) - coalesce(o.q, 0) <> 0
    order by 1
  loop
    if d.delta > 0 then perform sale_stock_take(cid, sl.id, d.pid, d.delta, sl.invoice_no);
    else perform sale_stock_return(cid, sl.id, d.pid, -d.delta, sl.invoice_no, 'Sale edited'); end if;
  end loop;

  insert into audit_logs(company_id, user_id, action, record_type, record_id, details)
    values (cid, auth.uid(), v_action, 'sale', sl.id::text, jsonb_build_object('invoice_no', sl.invoice_no, 'grand_total', sl.grand_total, 'payment_status', sl.payment_status));
  return jsonb_build_object('id', sl.id, 'invoice_no', sl.invoice_no, 'status', sl.status, 'grand_total', sl.grand_total,
                            'amount_paid', sl.amount_paid, 'balance_due', sl.balance_due, 'payment_status', sl.payment_status);
end $$;

-- ---------- Public RPCs ----------
create or replace function public.create_sale(p jsonb) returns jsonb
language sql security definer set search_path = public as $$ select public.sale_upsert(null::uuid, p) $$;

create or replace function public.update_sale(p_id uuid, p jsonb) returns jsonb
language sql security definer set search_path = public as $$ select public.sale_upsert(p_id, p) $$;

-- Cancel never deletes: all stock the sale took goes back to the same batches, the invoice stays as CANCELLED, and it stops counting
-- toward customer balances. A second cancel is refused, so stock cannot be restored twice.
create or replace function public.cancel_sale(p_id uuid, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare sl sales; d record;
begin
  select * into sl from sales where id = p_id for update;
  if sl.id is null or not has_role(sl.company_id, array['owner','manager']) then raise exception 'NOT_ALLOWED'; end if;
  if sl.status = 'cancelled' then raise exception 'ALREADY_CANCELLED'; end if;
  for d in select product_id, sum(quantity) as q from sale_batch_allocations where sale_id = sl.id group by 1 order by 1 loop
    perform sale_stock_return(sl.company_id, sl.id, d.product_id, d.q, sl.invoice_no, 'Sale cancelled');
  end loop;
  update sales set status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid(), cancel_reason = nullif(left(btrim(coalesce(p_reason, '')), 500), '')
    where id = sl.id returning * into sl;
  insert into audit_logs(company_id, user_id, action, record_type, record_id, details)
    values (sl.company_id, auth.uid(), 'sale_cancelled', 'sale', sl.id::text, jsonb_build_object('invoice_no', sl.invoice_no));
  return jsonb_build_object('id', sl.id, 'invoice_no', sl.invoice_no, 'status', sl.status);
end $$;

-- ---------- Read helpers (SECURITY INVOKER: RLS applies, so another shop's ids return nothing) ----------
-- Customer balance: > 0 the customer owes you, < 0 you owe the customer (advance). p_ids = null -> all customers of the company.
create or replace function public.customer_outstanding(p_company uuid, p_ids uuid[] default null)
returns table(customer_id uuid, opening numeric, sales_due numeric, outstanding numeric)
language sql stable set search_path = public as $$
  select c.id,
         case when c.balance_type = 'debit' then c.opening_balance else -c.opening_balance end,
         coalesce(sum(s.balance_due) filter (where s.status = 'completed'), 0),
         case when c.balance_type = 'debit' then c.opening_balance else -c.opening_balance end
           + coalesce(sum(s.balance_due) filter (where s.status = 'completed'), 0)
  from customers c
  left join sales s on s.customer_id = c.id and s.company_id = c.company_id
  where c.company_id = p_company and (p_ids is null or c.id = any(p_ids))
  group by c.id, c.balance_type, c.opening_balance $$;

-- What can actually be sold right now: total stock, and the part that is not in expired batches.
create or replace function public.product_sellable_stock(p_company uuid, p_ids uuid[])
returns table(product_id uuid, total numeric, sellable numeric)
language sql stable set search_path = public as $$
  select p.id, coalesce(i.quantity, 0),
         coalesce((select sum(b.quantity) from product_batches b where b.company_id = p.company_id and b.product_id = p.id
                   and (b.expiry_date is null or b.expiry_date >= public.today_ist())), 0)
  from products p left join inventory i on i.product_id = p.id and i.company_id = p.company_id
  where p.company_id = p_company and p.id = any(p_ids) $$;

-- Sales cards. p_date = the shop's "today" (sent by the browser so it follows the user's calendar day).
create or replace function public.sale_stats(p_company uuid, p_date date) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object(
    'today_total',   coalesce(t.total, 0), 'today_count', coalesce(t.cnt, 0), 'today_paid', coalesce(t.paid, 0), 'today_pending', coalesce(t.pending, 0),
    'pending_total', (select coalesce(sum(balance_due), 0) from sales where company_id = p_company and status = 'completed' and balance_due > 0))
  from (select sum(grand_total) as total, count(*) as cnt, sum(amount_paid) as paid, sum(balance_due) as pending
        from sales where company_id = p_company and status = 'completed' and sale_date = p_date) t $$;

-- ---------- Privileges ----------
revoke all on function public.sale_stock_take(uuid, uuid, uuid, numeric, text) from public, anon, authenticated;
revoke all on function public.sale_stock_return(uuid, uuid, uuid, numeric, text, text) from public, anon, authenticated;
revoke all on function public.sale_upsert(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.create_sale(jsonb), public.update_sale(uuid, jsonb), public.cancel_sale(uuid, text), public.customer_outstanding(uuid, uuid[]),
              public.product_sellable_stock(uuid, uuid[]), public.sale_stats(uuid, date), public.today_ist() from public, anon;
grant execute on function public.create_sale(jsonb), public.update_sale(uuid, jsonb), public.cancel_sale(uuid, text), public.customer_outstanding(uuid, uuid[]),
              public.product_sellable_stock(uuid, uuid[]), public.sale_stats(uuid, date), public.today_ist() to authenticated;
