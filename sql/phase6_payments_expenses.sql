-- Agro POS — Phase 6: payments + expenses.
-- ADDITIVE ONLY. Creates new tables/functions/triggers; never alters or drops Phase 1-5 objects (it only ADDS triggers to
-- sales, purchases and companies, and back-fills new rows). Safe to re-run.
-- Reuses: companies, customers, suppliers, sales, purchases, audit_logs, is_member(), has_role(), touch_updated_at(), today_ist().
-- Tenant column is `company_id` (this app's name for "shop_id").
--
-- WHAT EXISTED: payment data lived only on the invoice headers (sales / purchases: amount_paid, balance_due, payment_status;
-- sales also payment_method). A later payment could only overwrite amount_paid, so there was no payment history.
--
-- PAYMENTS DESIGN (one source of truth, no second payment system)
--  * `payments` is a LEDGER. For every sale/purchase, SUM(completed payments) = amount_paid on the invoice. Always.
--  * kind 'initial' = what was paid when the bill was made. It is created/updated automatically by triggers on sales/purchases
--    from amount_paid, so Phase 4/5 functions keep working unchanged, and existing invoices are back-filled below.
--  * kind 'payment' = a later payment, made ONLY through record_payments(); it raises amount_paid / lowers balance_due on the
--    invoice in the same transaction. void_payment() reverses it (the row stays, marked cancelled).
--  * Every payment is tied to a real invoice (composite FK keeps it in the same company) and to its customer/supplier.
--    direction 'in' = money received from a customer for a sale; 'out' = money paid to a supplier for a purchase.
--  * Clients can only READ payments. All writes are database functions (one transaction each).
--  * Roles: receiving customer money = owner/manager/cashier (a cashier already takes payment at billing); paying suppliers and
--    voiding a payment = owner/manager.
-- EXPENSES DESIGN
--  * expenses + expense_categories (9 defaults seeded per shop, owner/manager can add/rename/deactivate). Owner/manager only
--    (cashiers cannot even read them). Never deleted: cancelling sets status 'cancelled' (terminal; cancelled_by/at recorded by a trigger).
--  * "Net sales after expenses" is sales minus expenses. It is NOT profit (no cost-of-goods data).

do $$ begin
  if to_regclass('public.sales') is null or to_regclass('public.purchases') is null or to_regclass('public.customers') is null
     or to_regclass('public.suppliers') is null or to_regclass('public.audit_logs') is null
     or to_regprocedure('public.is_member(uuid)') is null or to_regprocedure('public.has_role(uuid,text[])') is null
     or to_regprocedure('public.touch_updated_at()') is null or to_regprocedure('public.today_ist()') is null then
    raise exception 'Phase 1-5 not found. Run the earlier SQL files first.';
  end if;
end $$;

-- =====================================================================================================================
-- PAYMENTS
-- =====================================================================================================================
create table if not exists public.payment_counters (       -- receipt numbers per shop and direction; no client access
  company_id uuid not null references public.companies(id) on delete cascade,
  direction text not null check (direction in ('in','out')),
  last_no integer not null default 0,
  primary key (company_id, direction));

create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  direction text not null check (direction in ('in','out')),
  kind text not null check (kind in ('initial','payment')),
  receipt_no text check (receipt_no is null or char_length(receipt_no) between 5 and 30),   -- groups the allocations of one receipt
  sale_id uuid,
  purchase_id uuid,
  party_id uuid,                                              -- customer or supplier (null for a walk-in sale)
  party_name text not null check (char_length(party_name) between 1 and 150),   -- name at the time of payment
  doc_no text not null check (char_length(doc_no) between 1 and 60),             -- invoice no / purchase no at the time of payment
  payment_method text not null check (payment_method in ('cash','upi','card','bank_transfer','other')),
  amount numeric(14,2) not null check (amount > 0),
  payment_date date not null,
  reference_number text check (reference_number is null or char_length(reference_number) <= 100),
  notes text check (notes is null or char_length(notes) <= 500),
  status text not null default 'completed' check (status in ('completed','cancelled')),
  cancel_reason text check (cancel_reason is null or char_length(cancel_reason) <= 500),
  cancelled_by uuid references auth.users(id),
  cancelled_at timestamptz,
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, company_id),
  foreign key (sale_id, company_id) references public.sales(id, company_id) on delete cascade,           -- same-company invoice only
  foreign key (purchase_id, company_id) references public.purchases(id, company_id) on delete cascade,
  check ((sale_id is not null) <> (purchase_id is not null)),
  check ((direction = 'in') = (sale_id is not null)),
  check (kind = 'payment' or (status = 'completed' and receipt_no is null)),
  check (kind = 'initial' or receipt_no is not null));

create unique index if not exists payments_initial_sale_uq on public.payments(sale_id) where kind = 'initial';
create unique index if not exists payments_initial_purchase_uq on public.payments(purchase_id) where kind = 'initial';
create index if not exists payments_company_date_idx on public.payments(company_id, payment_date desc, created_at desc);
create index if not exists payments_sale_idx on public.payments(sale_id) where sale_id is not null;
create index if not exists payments_purchase_idx on public.payments(purchase_id) where purchase_id is not null;
create index if not exists payments_company_dir_status_idx on public.payments(company_id, direction, status);
create index if not exists payments_company_receipt_idx on public.payments(company_id, receipt_no) where receipt_no is not null;

alter table public.payments enable row level security;
alter table public.payment_counters enable row level security;      -- no policies = no access
revoke all on public.payments, public.payment_counters from anon, authenticated;
grant select on public.payments to authenticated;
drop policy if exists payments_select on public.payments;
create policy payments_select on public.payments for select to authenticated using (public.is_member(company_id));

-- ---------- Triggers: keep the "initial" ledger row equal to (amount_paid - later payments) ----------
-- If someone lowers amount_paid below the later payments that were recorded, that is refused (PAYMENTS_EXIST): void them first.
create or replace function public.payments_sync_sale() returns trigger
language plpgsql security definer set search_path = public as $$
declare later numeric; init numeric;
begin
  select coalesce(sum(amount), 0) into later from payments where sale_id = new.id and kind = 'payment' and status = 'completed';
  init := new.amount_paid - later;
  if init < 0 then raise exception 'PAYMENTS_EXIST'; end if;
  if init = 0 then delete from payments where sale_id = new.id and kind = 'initial'; return new; end if;
  insert into payments(company_id, direction, kind, sale_id, party_id, party_name, doc_no, payment_method, amount, payment_date, created_by, created_at)
    values (new.company_id, 'in', 'initial', new.id, new.customer_id, new.customer_name, new.invoice_no,
            case new.payment_method when 'credit' then 'other' else new.payment_method end, init, new.sale_date, new.created_by, new.created_at)
  on conflict (sale_id) where kind = 'initial' do update set amount = excluded.amount, payment_date = excluded.payment_date,
    payment_method = excluded.payment_method, party_id = excluded.party_id, party_name = excluded.party_name, doc_no = excluded.doc_no, updated_at = now();
  return new;
end $$;

-- A purchase only has payments once it has been completed (a draft's "paid" figure is just a plan). completed_at stays set after a cancel.
create or replace function public.payments_sync_purchase() returns trigger
language plpgsql security definer set search_path = public as $$
declare later numeric; init numeric; sname text;
begin
  if new.completed_at is null then return new; end if;
  select coalesce(sum(amount), 0) into later from payments where purchase_id = new.id and kind = 'payment' and status = 'completed';
  init := new.amount_paid - later;
  if init < 0 then raise exception 'PAYMENTS_EXIST'; end if;
  if init = 0 then delete from payments where purchase_id = new.id and kind = 'initial'; return new; end if;
  select supplier_name into sname from suppliers where id = new.supplier_id and company_id = new.company_id;
  insert into payments(company_id, direction, kind, purchase_id, party_id, party_name, doc_no, payment_method, amount, payment_date, reference_number, created_by, created_at)
    values (new.company_id, 'out', 'initial', new.id, new.supplier_id, coalesce(sname, 'Supplier'), new.purchase_no, 'other', init, new.purchase_date, new.invoice_number, new.created_by, new.created_at)
  on conflict (purchase_id) where kind = 'initial' do update set amount = excluded.amount, payment_date = excluded.payment_date,
    party_id = excluded.party_id, party_name = excluded.party_name, doc_no = excluded.doc_no, reference_number = excluded.reference_number, updated_at = now();
  return new;
end $$;

drop trigger if exists sales_payments_ins on public.sales;
create trigger sales_payments_ins after insert on public.sales for each row execute function public.payments_sync_sale();
drop trigger if exists sales_payments_upd on public.sales;
create trigger sales_payments_upd after update on public.sales for each row
  when (old.amount_paid is distinct from new.amount_paid or old.sale_date is distinct from new.sale_date or old.payment_method is distinct from new.payment_method
        or old.customer_id is distinct from new.customer_id or old.customer_name is distinct from new.customer_name)
  execute function public.payments_sync_sale();
drop trigger if exists purchases_payments_ins on public.purchases;
create trigger purchases_payments_ins after insert on public.purchases for each row execute function public.payments_sync_purchase();
drop trigger if exists purchases_payments_upd on public.purchases;
create trigger purchases_payments_upd after update on public.purchases for each row
  when (old.amount_paid is distinct from new.amount_paid or old.purchase_date is distinct from new.purchase_date or old.supplier_id is distinct from new.supplier_id
        or old.completed_at is distinct from new.completed_at or old.invoice_number is distinct from new.invoice_number)
  execute function public.payments_sync_purchase();

-- ---------- Back-fill: one 'initial' ledger row for every existing invoice that already has money on it ----------
insert into public.payments(company_id, direction, kind, sale_id, party_id, party_name, doc_no, payment_method, amount, payment_date, created_by, created_at)
  select s.company_id, 'in', 'initial', s.id, s.customer_id, s.customer_name, s.invoice_no, case s.payment_method when 'credit' then 'other' else s.payment_method end,
         s.amount_paid, s.sale_date, s.created_by, s.created_at
  from public.sales s where s.amount_paid > 0
  on conflict do nothing;
insert into public.payments(company_id, direction, kind, purchase_id, party_id, party_name, doc_no, payment_method, amount, payment_date, reference_number, created_by, created_at)
  select p.company_id, 'out', 'initial', p.id, p.supplier_id, coalesce(su.supplier_name, 'Supplier'), p.purchase_no, 'other', p.amount_paid, p.purchase_date, p.invoice_number, p.created_by, p.created_at
  from public.purchases p left join public.suppliers su on su.id = p.supplier_id and su.company_id = p.company_id
  where p.amount_paid > 0 and p.completed_at is not null
  on conflict do nothing;

-- ---------- record_payments: later payments against one or more open invoices of ONE customer (in) or supplier (out) ----------
-- p = { company_id, direction: 'in'|'out', party_id, payment_method, payment_date, reference_number, notes,
--       allocations: [{doc_id, amount}] }   one ledger row per invoice; all rows of the call share one receipt number.
create or replace function public.record_payments(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  cid uuid; v_dir text; v_party uuid; v_pname text; v_method text; v_date date; v_ref text; v_notes text;
  a jsonb; v_id uuid; v_amt numeric; v_total numeric := 0; cnt int := 0; seen uuid[] := '{}'; n int; v_no text; sl sales; pu purchases;
begin
  cid := nullif(p->>'company_id','')::uuid; v_dir := p->>'direction';
  if v_dir is null or v_dir not in ('in','out') then raise exception 'INVALID_DIRECTION'; end if;
  if cid is null or not has_role(cid, case when v_dir = 'in' then array['owner','manager','cashier'] else array['owner','manager'] end) then
    raise exception 'NOT_ALLOWED'; end if;
  v_method := coalesce(nullif(p->>'payment_method',''), 'cash');
  if v_method not in ('cash','upi','card','bank_transfer','other') then raise exception 'INVALID_PAYMENT_METHOD'; end if;
  v_date := coalesce(nullif(p->>'payment_date','')::date, public.today_ist());
  if v_date > public.today_ist() + 1 or v_date < date '2000-01-01' then raise exception 'INVALID_DATE'; end if;
  v_ref := nullif(btrim(p->>'reference_number'), ''); v_notes := nullif(btrim(p->>'notes'), '');
  if char_length(coalesce(v_ref, '')) > 100 or char_length(coalesce(v_notes, '')) > 500 then raise exception 'TEXT_TOO_LONG'; end if;
  v_party := nullif(p->>'party_id','')::uuid;
  if v_dir = 'in' then select customer_name into v_pname from customers where id = v_party and company_id = cid;
  else select supplier_name into v_pname from suppliers where id = v_party and company_id = cid; end if;
  if v_pname is null then raise exception 'PARTY_NOT_FOUND'; end if;
  if jsonb_typeof(p->'allocations') is distinct from 'array' or jsonb_array_length(p->'allocations') = 0 then raise exception 'NO_ALLOCATIONS'; end if;
  if jsonb_array_length(p->'allocations') > 100 then raise exception 'TOO_MANY_ALLOCATIONS'; end if;

  insert into payment_counters(company_id, direction, last_no) values (cid, v_dir, 1)
    on conflict (company_id, direction) do update set last_no = payment_counters.last_no + 1 returning last_no into n;
  v_no := case when v_dir = 'in' then 'RCT-' else 'PAY-' end || lpad(n::text, 6, '0');

  for a in select value from jsonb_array_elements(p->'allocations') order by value->>'doc_id' loop     -- invoices locked in id order
    v_id := nullif(a->>'doc_id','')::uuid; v_amt := (a->>'amount')::numeric;
    if v_id is null then raise exception 'DOCUMENT_NOT_FOUND'; end if;
    if v_id = any(seen) then raise exception 'DUPLICATE_ALLOCATION'; end if;
    seen := seen || v_id;
    if v_amt is null or v_amt <= 0 or v_amt <> round(v_amt, 2) then raise exception 'INVALID_AMOUNT'; end if;
    if v_dir = 'in' then
      select * into sl from sales where id = v_id and company_id = cid and customer_id = v_party for update;
      if not found then raise exception 'DOCUMENT_NOT_FOUND'; end if;
      if sl.status <> 'completed' then raise exception 'DOCUMENT_CANCELLED'; end if;
      if v_amt > sl.balance_due then raise exception 'PAYMENT_EXCEEDS_DUE' using detail = sl.invoice_no || ':' || sl.balance_due::text; end if;
      insert into payments(company_id, direction, kind, receipt_no, sale_id, party_id, party_name, doc_no, payment_method, amount, payment_date, reference_number, notes)
        values (cid, 'in', 'payment', v_no, sl.id, v_party, v_pname, sl.invoice_no, v_method, v_amt, v_date, v_ref, v_notes);
      update sales set amount_paid = amount_paid + v_amt, balance_due = balance_due - v_amt,
             payment_status = case when balance_due - v_amt = 0 then 'paid' else 'partial' end where id = sl.id;
    else
      select * into pu from purchases where id = v_id and company_id = cid and supplier_id = v_party for update;
      if not found then raise exception 'DOCUMENT_NOT_FOUND'; end if;
      if pu.status = 'draft' then raise exception 'DOCUMENT_NOT_COMPLETED'; end if;
      if pu.status <> 'completed' then raise exception 'DOCUMENT_CANCELLED'; end if;
      if v_amt > pu.balance_due then raise exception 'PAYMENT_EXCEEDS_DUE' using detail = pu.purchase_no || ':' || pu.balance_due::text; end if;
      insert into payments(company_id, direction, kind, receipt_no, purchase_id, party_id, party_name, doc_no, payment_method, amount, payment_date, reference_number, notes)
        values (cid, 'out', 'payment', v_no, pu.id, v_party, v_pname, pu.purchase_no, v_method, v_amt, v_date, v_ref, v_notes);
      update purchases set amount_paid = amount_paid + v_amt, balance_due = balance_due - v_amt,
             payment_status = case when balance_due - v_amt = 0 then 'paid' else 'partial' end where id = pu.id;
    end if;
    v_total := v_total + v_amt; cnt := cnt + 1;
  end loop;

  insert into audit_logs(company_id, user_id, action, record_type, record_id, details)
    values (cid, auth.uid(), case when v_dir = 'in' then 'payment_received' else 'payment_made' end, 'payment', v_no,
            jsonb_build_object('total', v_total, 'invoices', cnt, 'method', v_method, 'party', v_pname));
  return jsonb_build_object('receipt_no', v_no, 'total', v_total, 'count', cnt);
end $$;

-- ---------- void_payment: reverse one LATER payment (never deletes; the row stays, marked cancelled) ----------
create or replace function public.void_payment(p_id uuid, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pay payments; sl sales; pu purchases;
begin
  select * into pay from payments where id = p_id;
  if pay.id is null or not has_role(pay.company_id, array['owner','manager']) then raise exception 'NOT_ALLOWED'; end if;
  if pay.kind <> 'payment' then raise exception 'CANNOT_VOID_INITIAL'; end if;     -- the at-billing amount is changed by editing the invoice
  if pay.sale_id is not null then select * into sl from sales where id = pay.sale_id for update;       -- invoice first, same order as record_payments
  else select * into pu from purchases where id = pay.purchase_id for update; end if;
  select * into pay from payments where id = p_id for update;
  if pay.status = 'cancelled' then raise exception 'ALREADY_CANCELLED'; end if;
  update payments set status = 'cancelled', cancelled_by = auth.uid(), cancelled_at = now(),
         cancel_reason = nullif(left(btrim(coalesce(p_reason, '')), 500), ''), updated_at = now() where id = pay.id;
  if pay.sale_id is not null then
    update sales set amount_paid = amount_paid - pay.amount, balance_due = balance_due + pay.amount,
           payment_status = case when amount_paid - pay.amount = 0 then 'pending' when amount_paid - pay.amount >= grand_total then 'paid' else 'partial' end
     where id = pay.sale_id;
  else
    update purchases set amount_paid = amount_paid - pay.amount, balance_due = balance_due + pay.amount,
           payment_status = case when amount_paid - pay.amount = 0 then 'unpaid' when amount_paid - pay.amount >= grand_total then 'paid' else 'partial' end
     where id = pay.purchase_id;
  end if;
  insert into audit_logs(company_id, user_id, action, record_type, record_id, details)
    values (pay.company_id, auth.uid(), 'payment_voided', 'payment', pay.receipt_no, jsonb_build_object('amount', pay.amount, 'doc_no', pay.doc_no));
  return jsonb_build_object('id', pay.id, 'status', 'cancelled');
end $$;

-- =====================================================================================================================
-- EXPENSES
-- =====================================================================================================================
create table if not exists public.expense_categories (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 60),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, company_id));
create unique index if not exists expense_categories_company_name_uq on public.expense_categories(company_id, lower(btrim(name)));

create table if not exists public.expenses (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  expense_date date not null default current_date,
  category_id uuid not null,
  description text not null check (char_length(btrim(description)) between 1 and 200),
  amount numeric(14,2) not null check (amount > 0),
  payment_method text not null default 'cash' check (payment_method in ('cash','upi','card','bank_transfer','other')),
  reference_number text check (reference_number is null or char_length(reference_number) <= 100),
  notes text check (notes is null or char_length(notes) <= 500),
  status text not null default 'active' check (status in ('active','cancelled')),
  cancel_reason text check (cancel_reason is null or char_length(cancel_reason) <= 500),
  cancelled_by uuid references auth.users(id),
  cancelled_at timestamptz,
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, company_id),
  foreign key (category_id, company_id) references public.expense_categories(id, company_id));   -- category must belong to the same shop
create index if not exists expenses_company_date_idx on public.expenses(company_id, expense_date desc, created_at desc);
create index if not exists expenses_company_category_idx on public.expenses(company_id, category_id);
create index if not exists expenses_company_status_idx on public.expenses(company_id, status);

drop trigger if exists expense_categories_touch on public.expense_categories;
create trigger expense_categories_touch before update on public.expense_categories for each row execute function public.touch_updated_at();
drop trigger if exists expenses_touch on public.expenses;
create trigger expenses_touch before update on public.expenses for each row execute function public.touch_updated_at();

-- Trims text, validates the date, locks company/creator, makes 'cancelled' a one-way door and stamps who/when cancelled.
-- SECURITY DEFINER only so the category lookup is not hidden by RLS: an unauthorised insert then fails with a clear 'permission denied'
-- from the row-level policy instead of a misleading 'category inactive'.
create or replace function public.expenses_before_write() returns trigger language plpgsql security definer set search_path = public as $$
declare cat expense_categories;
begin
  new.description := btrim(new.description); new.reference_number := nullif(btrim(new.reference_number), ''); new.notes := nullif(btrim(new.notes), '');
  if new.expense_date > public.today_ist() + 1 or new.expense_date < date '2000-01-01' then raise exception 'INVALID_DATE'; end if;
  if tg_op = 'INSERT' then
    new.status := 'active'; new.cancelled_at := null; new.cancelled_by := null; new.cancel_reason := null;
  else
    if new.company_id is distinct from old.company_id then raise exception 'COMPANY_IMMUTABLE'; end if;
    if old.status = 'cancelled' then raise exception 'EXPENSE_CANCELLED'; end if;
    new.created_by := old.created_by; new.created_at := old.created_at;
    if new.status = 'cancelled' then
      new.cancelled_at := now(); new.cancelled_by := auth.uid(); new.cancel_reason := nullif(left(btrim(coalesce(new.cancel_reason, '')), 500), '');
    else new.cancelled_at := null; new.cancelled_by := null; new.cancel_reason := null; end if;
  end if;
  if tg_op = 'INSERT' or new.category_id is distinct from old.category_id then
    select * into cat from expense_categories where id = new.category_id and company_id = new.company_id;
    if not found or not cat.is_active then raise exception 'CATEGORY_INACTIVE'; end if;
  end if;
  return new;
end $$;
drop trigger if exists expenses_before_write on public.expenses;
create trigger expenses_before_write before insert or update on public.expenses for each row execute function public.expenses_before_write();

create or replace function public.expense_categories_before_write() returns trigger language plpgsql as $$
begin
  new.name := btrim(new.name);
  if tg_op = 'UPDATE' and new.company_id is distinct from old.company_id then raise exception 'COMPANY_IMMUTABLE'; end if;
  return new;
end $$;
drop trigger if exists expense_categories_before_write on public.expense_categories;
create trigger expense_categories_before_write before insert or update on public.expense_categories for each row execute function public.expense_categories_before_write();

-- Default categories for every shop: existing shops now, new shops via a trigger on companies.
create or replace function public.expense_seed_categories(p_company uuid) returns void
language sql security definer set search_path = public as $$
  insert into expense_categories(company_id, name)
    select p_company, n from unnest(array['Rent','Electricity','Transport','Labour','Packaging','Maintenance','Fuel','Office','Other']) as n
  on conflict do nothing $$;
create or replace function public.companies_seed_expense_categories() returns trigger
language plpgsql security definer set search_path = public as $$ begin perform public.expense_seed_categories(new.id); return new; end $$;
drop trigger if exists companies_seed_expense_cats on public.companies;
create trigger companies_seed_expense_cats after insert on public.companies for each row execute function public.companies_seed_expense_categories();
select public.expense_seed_categories(id) from public.companies;

alter table public.expense_categories enable row level security;
alter table public.expenses enable row level security;
revoke all on public.expense_categories, public.expenses from anon, authenticated;
grant select, insert, update on public.expense_categories, public.expenses to authenticated;      -- never DELETE
do $$ declare t text; begin
  foreach t in array array['expense_categories','expenses'] loop
    execute format('drop policy if exists %I_select on public.%I', t, t);
    execute format('drop policy if exists %I_insert on public.%I', t, t);
    execute format('drop policy if exists %I_update on public.%I', t, t);
    execute format('create policy %I_select on public.%I for select to authenticated using (public.has_role(company_id, array[''owner'',''manager'']))', t, t);
    execute format('create policy %I_update on public.%I for update to authenticated using (public.has_role(company_id, array[''owner'',''manager''])) with check (public.has_role(company_id, array[''owner'',''manager'']))', t, t);
  end loop;
end $$;
create policy expense_categories_insert on public.expense_categories for insert to authenticated with check (public.has_role(company_id, array['owner','manager']));
create policy expenses_insert on public.expenses for insert to authenticated
  with check (public.has_role(company_id, array['owner','manager']) and (created_by is null or created_by = auth.uid()));

-- =====================================================================================================================
-- Dashboard / page figures (SECURITY INVOKER: RLS applies; cashiers get 0 for expenses). p_date = the shop's "today" from the browser.
-- Payments on a CANCELLED invoice are not counted as money in/out. Receivable/payable include opening balances.
-- =====================================================================================================================
create or replace function public.finance_stats(p_company uuid, p_date date) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object(
    'today_expenses', (select coalesce(sum(amount), 0) from expenses where company_id = p_company and status = 'active' and expense_date = p_date),
    'month_expenses', (select coalesce(sum(amount), 0) from expenses where company_id = p_company and status = 'active'
                        and expense_date >= date_trunc('month', p_date)::date and expense_date <= p_date),
    'money_in_today', (select coalesce(sum(p.amount), 0) from payments p where p.company_id = p_company and p.direction = 'in' and p.status = 'completed' and p.payment_date = p_date
                        and exists (select 1 from sales s where s.id = p.sale_id and s.company_id = p.company_id and s.status = 'completed')),
    'money_out_today', (select coalesce(sum(p.amount), 0) from payments p where p.company_id = p_company and p.direction = 'out' and p.status = 'completed' and p.payment_date = p_date
                        and exists (select 1 from purchases u where u.id = p.purchase_id and u.company_id = p.company_id and u.status = 'completed')),
    'receivable', (select coalesce(sum(case when balance_type = 'debit' then opening_balance else -opening_balance end), 0) from customers where company_id = p_company)
                  + (select coalesce(sum(balance_due), 0) from sales where company_id = p_company and status = 'completed'),
    'payable', (select coalesce(sum(case when balance_type = 'credit' then opening_balance else -opening_balance end), 0) from suppliers where company_id = p_company)
               + (select coalesce(sum(balance_due), 0) from purchases where company_id = p_company and status = 'completed')) $$;

-- ---------- Privileges ----------
revoke all on function public.payments_sync_sale(), public.payments_sync_purchase(), public.expense_seed_categories(uuid), public.companies_seed_expense_categories(), public.expenses_before_write() from public, anon, authenticated;
revoke all on function public.record_payments(jsonb), public.void_payment(uuid, text), public.finance_stats(uuid, date) from public, anon;
grant execute on function public.record_payments(jsonb), public.void_payment(uuid, text), public.finance_stats(uuid, date) to authenticated;
