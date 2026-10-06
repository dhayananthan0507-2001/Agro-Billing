-- Agro POS — Phase 4: purchase management.
-- ADDITIVE ONLY. Creates new tables/functions; never alters or drops Phase 1-3 objects. Safe to re-run.
-- Reuses: companies, suppliers, products, inventory, product_batches, inventory_movements, audit_logs,
--         is_member(), has_role(), touch_updated_at().
-- Tenant column is `company_id` (this app's name for "shop_id").
--
-- DESIGN
--  * purchases / purchase_items are READ-ONLY for clients (RLS select only, no insert/update/delete grants).
--    All writes go through create_purchase / update_purchase / cancel_purchase, which run as one transaction:
--    header + items + stock (batch + inventory + movement) + audit. Any error rolls everything back.
--  * Totals are computed IN THE DATABASE from the items (numeric, never floats); the browser's numbers are previews.
--  * Stock follows Phase 2's rule "inventory total = sum of batch quantities", so each purchase line goes into a batch
--    (batch number given on the line, else the purchase number e.g. PUR-000123).
--  * Supplier balance is DERIVED (never stored):
--        outstanding = signed opening balance + sum(balance_due of COMPLETED purchases)
--    signed opening: balance_type 'credit' (shop owes supplier) = +opening, 'debit' = -opening. Positive = you owe the supplier.
--  * Money rules: item taxable = round(qty*price,2) - item discount; item tax = round(taxable*rate/100,2);
--    subtotal = sum(taxable); tax = sum(item tax); grand_total = subtotal - purchase discount + tax + additional charges.

do $$ begin
  if to_regclass('public.suppliers') is null or to_regclass('public.products') is null
     or to_regclass('public.inventory') is null or to_regclass('public.product_batches') is null
     or to_regclass('public.inventory_movements') is null or to_regclass('public.audit_logs') is null
     or to_regprocedure('public.is_member(uuid)') is null or to_regprocedure('public.has_role(uuid,text[])') is null
     or to_regprocedure('public.touch_updated_at()') is null then
    raise exception 'Phase 1-3 not found. Run the earlier SQL files first.';
  end if;
end $$;

-- ---------- Tables ----------
create table if not exists public.purchase_counters (   -- per-company running number; no client access
  company_id uuid primary key references public.companies(id) on delete cascade,
  last_no integer not null default 0);

create table if not exists public.purchases (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  supplier_id uuid not null,
  purchase_no text not null check (purchase_no ~ '^PUR-[0-9]{6,}$'),
  invoice_number text check (invoice_number is null or char_length(invoice_number) between 1 and 60),
  purchase_date date not null default current_date,
  subtotal numeric(14,2) not null default 0 check (subtotal >= 0),
  discount numeric(14,2) not null default 0 check (discount >= 0),
  tax numeric(14,2) not null default 0 check (tax >= 0),
  additional_charges numeric(14,2) not null default 0 check (additional_charges >= 0),
  grand_total numeric(14,2) not null default 0 check (grand_total >= 0),
  amount_paid numeric(14,2) not null default 0 check (amount_paid >= 0),
  balance_due numeric(14,2) not null default 0 check (balance_due >= 0),
  payment_status text not null default 'unpaid' check (payment_status in ('unpaid','partial','paid')),
  notes text check (notes is null or char_length(notes) <= 1000),
  status text not null default 'draft' check (status in ('draft','completed','cancelled')),
  completed_at timestamptz,
  cancelled_at timestamptz,
  cancel_reason text check (cancel_reason is null or char_length(cancel_reason) <= 500),
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, company_id),
  unique (company_id, purchase_no),
  foreign key (supplier_id, company_id) references public.suppliers(id, company_id),   -- supplier must be in the same company
  check (grand_total = subtotal - discount + tax + additional_charges),
  check (amount_paid <= grand_total),
  check (balance_due = grand_total - amount_paid));

create table if not exists public.purchase_items (
  id uuid primary key default gen_random_uuid(),
  purchase_id uuid not null,
  company_id uuid not null references public.companies(id) on delete cascade,
  line_no integer not null check (line_no > 0),
  product_id uuid not null,
  quantity numeric(14,3) not null check (quantity > 0),
  unit_price numeric(12,2) not null check (unit_price >= 0),
  discount numeric(12,2) not null default 0 check (discount >= 0),
  tax_rate numeric(5,2) not null default 0 check (tax_rate between 0 and 100),
  tax numeric(12,2) not null default 0 check (tax >= 0),
  line_total numeric(14,2) not null check (line_total >= 0),
  batch_number text not null check (char_length(btrim(batch_number)) between 1 and 60),
  manufacturing_date date,
  expiry_date date,
  created_at timestamptz not null default now(),
  unique (purchase_id, line_no),
  check (expiry_date is null or manufacturing_date is null or expiry_date >= manufacturing_date),
  foreign key (purchase_id, company_id) references public.purchases(id, company_id) on delete cascade,
  foreign key (product_id, company_id) references public.products(id, company_id));   -- product must be in the same company

-- ---------- Indexes ----------
create index if not exists purchases_company_date_idx     on public.purchases(company_id, purchase_date desc, created_at desc);
create index if not exists purchases_company_supplier_idx on public.purchases(company_id, supplier_id);
create index if not exists purchases_company_status_idx   on public.purchases(company_id, status);
-- Same supplier cannot reuse an invoice number inside one shop (cancelled purchases free the number again).
create unique index if not exists purchases_company_supplier_invoice_uq
  on public.purchases(company_id, supplier_id, lower(invoice_number)) where invoice_number is not null and status <> 'cancelled';
create index if not exists purchase_items_purchase_idx on public.purchase_items(purchase_id);
create index if not exists purchase_items_company_product_idx on public.purchase_items(company_id, product_id);

drop trigger if exists purchases_touch on public.purchases;
create trigger purchases_touch before update on public.purchases for each row execute function public.touch_updated_at();

-- ---------- RLS: members can read; nobody writes directly ----------
alter table public.purchases enable row level security;
alter table public.purchase_items enable row level security;
alter table public.purchase_counters enable row level security;      -- no policies = no access

revoke all on public.purchases, public.purchase_items, public.purchase_counters from anon, authenticated;
grant select on public.purchases, public.purchase_items to authenticated;

drop policy if exists purchases_select on public.purchases;
create policy purchases_select on public.purchases for select to authenticated using (public.is_member(company_id));
drop policy if exists purchase_items_select on public.purchase_items;
create policy purchase_items_select on public.purchase_items for select to authenticated using (public.is_member(company_id));

-- ---------- Internal: move stock for one (product, batch) by a signed amount ----------
-- Lock order matches Phase 2's adjust_stock(): batch row first, then inventory row.
create or replace function public.purchase_stock_move(
  p_cid uuid, p_product uuid, p_batch text, p_delta numeric, p_mfg date, p_exp date, p_price numeric, p_ref text, p_note text)
returns void language plpgsql set search_path = public as $$
declare b product_batches; inv inventory;
begin
  if p_delta is null or p_delta = 0 then return; end if;
  select * into b from product_batches where company_id = p_cid and product_id = p_product and batch_number = p_batch for update;
  if not found then
    if p_delta < 0 then raise exception 'INSUFFICIENT_STOCK'; end if;
    insert into product_batches(company_id, product_id, batch_number, manufacturing_date, expiry_date, quantity, purchase_price)
      values (p_cid, p_product, p_batch, p_mfg, p_exp, 0, p_price) returning * into b;
  elsif p_delta > 0 then
    if (p_mfg is not null and b.manufacturing_date is not null and p_mfg <> b.manufacturing_date)
       or (p_exp is not null and b.expiry_date is not null and p_exp <> b.expiry_date) then
      raise exception 'BATCH_DATE_MISMATCH';   -- same batch number but different dates: refuse rather than guess
    end if;
    update product_batches set manufacturing_date = coalesce(manufacturing_date, p_mfg), expiry_date = coalesce(expiry_date, p_exp) where id = b.id;
  end if;
  if b.quantity + p_delta < 0 then raise exception 'INSUFFICIENT_STOCK'; end if;
  select * into inv from inventory where company_id = p_cid and product_id = p_product for update;
  if not found then
    insert into inventory(company_id, product_id, quantity) values (p_cid, p_product, 0) on conflict (company_id, product_id) do nothing;
    select * into inv from inventory where company_id = p_cid and product_id = p_product for update;
  end if;
  if inv.quantity + p_delta < 0 then raise exception 'INSUFFICIENT_STOCK'; end if;
  update product_batches set quantity = quantity + p_delta where id = b.id;
  update inventory set quantity = quantity + p_delta, updated_at = now() where id = inv.id;
  insert into inventory_movements(company_id, product_id, batch_id, movement_type, quantity, previous_quantity, new_quantity, reference_type, reference_id, notes)
    values (p_cid, p_product, b.id, case when p_delta > 0 then 'purchase' else 'purchase_return' end,
            p_delta, inv.quantity, inv.quantity + p_delta, 'purchase', p_ref, p_note);
end $$;

-- ---------- Internal: create (p_id null) or update one purchase, all in the caller's transaction ----------
-- p = { company_id (create only), supplier_id, invoice_number, purchase_date, discount, additional_charges, amount_paid,
--       notes, status: 'draft'|'completed', items: [{product_id, quantity, unit_price, discount, tax_rate,
--       batch_number, manufacturing_date, expiry_date}] }
-- Editing a COMPLETED purchase applies only the NET stock difference per (product, batch), so stock can never double.
create or replace function public.purchase_upsert(p_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  cid uuid; pur purchases; old_status text; v_status text; sup suppliers; prod products;
  it jsonb; idx int := 0; lines jsonb := '[]'::jsonb; v_old jsonb := '[]'::jsonb;
  qty numeric; price numeric; idisc numeric; rate numeric; gross numeric; taxable numeric; tx numeric; lt numeric;
  bn text; v_mfg date; v_exp date;
  v_sub numeric := 0; v_tax numeric := 0; v_disc numeric; v_add numeric; v_paid numeric; v_grand numeric; v_pay text;
  v_date date; v_inv text; v_notes text; n int; v_no text; d record; v_action text;
begin
  if p_id is null then cid := nullif(p->>'company_id','')::uuid;
  else
    select * into pur from purchases where id = p_id for update;
    cid := pur.company_id; old_status := pur.status;
  end if;
  -- An unknown id and another shop's id both answer NOT_ALLOWED (no probing).
  if cid is null or not has_role(cid, array['owner','manager']) then raise exception 'NOT_ALLOWED'; end if;

  if p_id is not null and old_status = 'cancelled' then raise exception 'PURCHASE_CANCELLED'; end if;
  v_status := coalesce(nullif(p->>'status',''), case when p_id is null then 'draft' else old_status end);
  if v_status not in ('draft','completed') then raise exception 'INVALID_STATUS'; end if;
  if p_id is not null and old_status = 'completed' and v_status = 'draft' then raise exception 'CANNOT_REVERT_TO_DRAFT'; end if;

  select * into sup from suppliers where id = nullif(p->>'supplier_id','')::uuid and company_id = cid;
  if not found then raise exception 'SUPPLIER_NOT_FOUND'; end if;
  if not sup.is_active and (p_id is null or sup.id <> pur.supplier_id) then raise exception 'SUPPLIER_INACTIVE'; end if;

  v_date := coalesce(nullif(p->>'purchase_date','')::date, current_date);
  if v_date > current_date + 1 or v_date < date '2000-01-01' then raise exception 'INVALID_DATE'; end if;
  v_inv := nullif(btrim(p->>'invoice_number'), ''); v_notes := nullif(btrim(p->>'notes'), '');
  v_disc := coalesce(nullif(p->>'discount','')::numeric, 0);
  v_add  := coalesce(nullif(p->>'additional_charges','')::numeric, 0);
  v_paid := coalesce(nullif(p->>'amount_paid','')::numeric, 0);
  if v_disc < 0 or v_add < 0 or v_paid < 0 or v_disc <> round(v_disc,2) or v_add <> round(v_add,2) or v_paid <> round(v_paid,2) then
    raise exception 'INVALID_AMOUNT'; end if;

  if jsonb_typeof(p->'items') is distinct from 'array' or jsonb_array_length(p->'items') = 0 then raise exception 'NO_ITEMS'; end if;
  if jsonb_array_length(p->'items') > 200 then raise exception 'TOO_MANY_ITEMS'; end if;

  for it in select value from jsonb_array_elements(p->'items') loop
    idx := idx + 1;
    qty   := (it->>'quantity')::numeric;
    price := coalesce(nullif(it->>'unit_price','')::numeric, 0);
    idisc := coalesce(nullif(it->>'discount','')::numeric, 0);
    rate  := coalesce(nullif(it->>'tax_rate','')::numeric, 0);
    if qty is null or qty <= 0 or qty <> round(qty,3) then raise exception 'INVALID_QUANTITY'; end if;
    if price < 0 or price <> round(price,2) or idisc < 0 or idisc <> round(idisc,2) or rate < 0 or rate > 100 or rate <> round(rate,2) then
      raise exception 'INVALID_AMOUNT'; end if;
    select * into prod from products where id = nullif(it->>'product_id','')::uuid and company_id = cid;
    if not found then raise exception 'PRODUCT_NOT_FOUND'; end if;
    if not prod.is_active and not (p_id is not null and exists (select 1 from purchase_items where purchase_id = p_id and product_id = prod.id)) then
      raise exception 'PRODUCT_INACTIVE'; end if;
    gross := round(qty * price, 2);
    if idisc > gross then raise exception 'DISCOUNT_TOO_HIGH'; end if;
    taxable := gross - idisc; tx := round(taxable * rate / 100, 2); lt := taxable + tx;
    bn := nullif(btrim(it->>'batch_number'), '');
    if bn is not null and char_length(bn) > 60 then raise exception 'INVALID_AMOUNT'; end if;
    v_mfg := nullif(it->>'manufacturing_date','')::date; v_exp := nullif(it->>'expiry_date','')::date;
    if v_mfg is not null and v_exp is not null and v_exp < v_mfg then raise exception 'INVALID_DATE'; end if;
    v_sub := v_sub + taxable; v_tax := v_tax + tx;
    lines := lines || jsonb_build_object('line_no', idx, 'product_id', prod.id, 'quantity', qty, 'unit_price', price, 'discount', idisc,
      'tax_rate', rate, 'tax', tx, 'line_total', lt, 'batch_number', bn, 'manufacturing_date', v_mfg, 'expiry_date', v_exp);
  end loop;

  if v_disc > v_sub then raise exception 'DISCOUNT_TOO_HIGH'; end if;
  v_grand := v_sub - v_disc + v_tax + v_add;
  if v_paid > v_grand then raise exception 'PAID_EXCEEDS_TOTAL'; end if;
  v_pay := case when v_paid >= v_grand then 'paid' when v_paid = 0 then 'unpaid' else 'partial' end;

  if p_id is null then
    insert into purchase_counters(company_id, last_no) values (cid, 1)
      on conflict (company_id) do update set last_no = purchase_counters.last_no + 1 returning last_no into n;
    v_no := 'PUR-' || lpad(n::text, 6, '0');
    insert into purchases(company_id, supplier_id, purchase_no, invoice_number, purchase_date, subtotal, discount, tax, additional_charges,
        grand_total, amount_paid, balance_due, payment_status, notes, status, completed_at)
      values (cid, sup.id, v_no, v_inv, v_date, v_sub, v_disc, v_tax, v_add, v_grand, v_paid, v_grand - v_paid, v_pay, v_notes, v_status,
        case when v_status = 'completed' then now() end)
      returning * into pur;
    v_action := case when v_status = 'completed' then 'purchase_completed' else 'purchase_created' end;
  else
    if old_status = 'completed' then
      v_old := coalesce((select jsonb_agg(jsonb_build_object('product_id', product_id, 'batch_number', batch_number, 'q', q))
                         from (select product_id, batch_number, sum(quantity) q from purchase_items where purchase_id = p_id group by 1, 2) s), '[]'::jsonb);
    end if;
    delete from purchase_items where purchase_id = p_id;
    update purchases set supplier_id = sup.id, invoice_number = v_inv, purchase_date = v_date, subtotal = v_sub, discount = v_disc, tax = v_tax,
        additional_charges = v_add, grand_total = v_grand, amount_paid = v_paid, balance_due = v_grand - v_paid, payment_status = v_pay,
        notes = v_notes, status = v_status,
        completed_at = case when old_status <> 'completed' and v_status = 'completed' then now() else completed_at end
      where id = p_id returning * into pur;
    v_action := case when old_status <> 'completed' and v_status = 'completed' then 'purchase_completed' else 'purchase_updated' end;
  end if;

  insert into purchase_items(purchase_id, company_id, line_no, product_id, quantity, unit_price, discount, tax_rate, tax, line_total,
      batch_number, manufacturing_date, expiry_date)
    select pur.id, cid, l.line_no, l.product_id, l.quantity, l.unit_price, l.discount, l.tax_rate, l.tax, l.line_total,
           coalesce(l.batch_number, pur.purchase_no), l.manufacturing_date, l.expiry_date
    from jsonb_to_recordset(lines) as l(line_no int, product_id uuid, quantity numeric, unit_price numeric, discount numeric, tax_rate numeric,
                                        tax numeric, line_total numeric, batch_number text, manufacturing_date date, expiry_date date);

  -- Stock: only a COMPLETED purchase touches stock; apply the net change per (product, batch).
  if v_status = 'completed' then
    for d in
      select coalesce(nw.product_id, o.product_id) as pid, coalesce(nw.bn, o.bn) as bn,
             coalesce(nw.q, 0) - coalesce(o.q, 0) as delta, nw.mfg, nw.exp_d, nw.price,
             coalesce(nw.nmd, 0) as nmd, coalesce(nw.ned, 0) as ned
      from (select product_id, batch_number as bn, sum(quantity) as q, min(manufacturing_date) as mfg, min(expiry_date) as exp_d,
                   min(unit_price) as price, count(distinct manufacturing_date) as nmd, count(distinct expiry_date) as ned
            from purchase_items where purchase_id = pur.id group by 1, 2) nw
      full join (select product_id, batch_number as bn, q from jsonb_to_recordset(v_old) as x(product_id uuid, batch_number text, q numeric)) o
        on o.product_id = nw.product_id and o.bn = nw.bn
      where coalesce(nw.q, 0) - coalesce(o.q, 0) <> 0
      order by 1, 2
    loop
      if d.nmd > 1 or d.ned > 1 then raise exception 'BATCH_DATE_MISMATCH'; end if;
      perform purchase_stock_move(cid, d.pid, d.bn, d.delta, d.mfg, d.exp_d, d.price, pur.purchase_no,
                                  case when old_status = 'completed' then 'Purchase edited' else 'Purchase' end);
    end loop;
  end if;

  insert into audit_logs(company_id, user_id, action, record_type, record_id, details)
    values (cid, auth.uid(), v_action, 'purchase', pur.id::text,
            jsonb_build_object('purchase_no', pur.purchase_no, 'status', pur.status, 'grand_total', pur.grand_total));
  return jsonb_build_object('id', pur.id, 'purchase_no', pur.purchase_no, 'status', pur.status, 'grand_total', pur.grand_total,
                            'amount_paid', pur.amount_paid, 'balance_due', pur.balance_due, 'payment_status', pur.payment_status);
end $$;

-- ---------- Public RPCs ----------
create or replace function public.create_purchase(p jsonb) returns jsonb
language sql security definer set search_path = public as $$ select public.purchase_upsert(null::uuid, p) $$;

create or replace function public.update_purchase(p_id uuid, p jsonb) returns jsonb
language sql security definer set search_path = public as $$ select public.purchase_upsert(p_id, p) $$;

-- Cancel never deletes: a completed purchase's stock is reversed (movement type 'purchase_return') and it stops counting
-- toward the supplier balance. If the stock was already used/sold the whole cancel is refused (INSUFFICIENT_STOCK).
create or replace function public.cancel_purchase(p_id uuid, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pur purchases; d record;
begin
  select * into pur from purchases where id = p_id for update;
  if pur.id is null or not has_role(pur.company_id, array['owner','manager']) then raise exception 'NOT_ALLOWED'; end if;
  if pur.status = 'cancelled' then raise exception 'ALREADY_CANCELLED'; end if;
  if pur.status = 'completed' then
    for d in select product_id, batch_number, sum(quantity) as q from purchase_items where purchase_id = pur.id group by 1, 2 order by 1, 2 loop
      perform purchase_stock_move(pur.company_id, d.product_id, d.batch_number, -d.q, null, null, null, pur.purchase_no, 'Purchase cancelled');
    end loop;
  end if;
  update purchases set status = 'cancelled', cancelled_at = now(), cancel_reason = nullif(left(btrim(coalesce(p_reason, '')), 500), '')
    where id = pur.id returning * into pur;
  insert into audit_logs(company_id, user_id, action, record_type, record_id, details)
    values (pur.company_id, auth.uid(), 'purchase_cancelled', 'purchase', pur.id::text, jsonb_build_object('purchase_no', pur.purchase_no));
  return jsonb_build_object('id', pur.id, 'purchase_no', pur.purchase_no, 'status', pur.status);
end $$;

-- ---------- Supplier balance (derived; SECURITY INVOKER so RLS applies) ----------
-- outstanding > 0: you owe the supplier.  < 0: supplier owes you (advance).  p_ids = null -> all suppliers of the company.
create or replace function public.supplier_outstanding(p_company uuid, p_ids uuid[] default null)
returns table(supplier_id uuid, opening numeric, purchases_due numeric, outstanding numeric)
language sql stable set search_path = public as $$
  select s.id,
         case when s.balance_type = 'credit' then s.opening_balance else -s.opening_balance end,
         coalesce(sum(p.balance_due) filter (where p.status = 'completed'), 0),
         case when s.balance_type = 'credit' then s.opening_balance else -s.opening_balance end
           + coalesce(sum(p.balance_due) filter (where p.status = 'completed'), 0)
  from suppliers s
  left join purchases p on p.supplier_id = s.id and p.company_id = s.company_id
  where s.company_id = p_company and (p_ids is null or s.id = any(p_ids))
  group by s.id, s.balance_type, s.opening_balance $$;

-- ---------- Privileges ----------
revoke all on function public.purchase_stock_move(uuid, uuid, text, numeric, date, date, numeric, text, text) from public, anon, authenticated;
revoke all on function public.purchase_upsert(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.create_purchase(jsonb), public.update_purchase(uuid, jsonb), public.cancel_purchase(uuid, text),
              public.supplier_outstanding(uuid, uuid[]) from public, anon;
grant execute on function public.create_purchase(jsonb), public.update_purchase(uuid, jsonb), public.cancel_purchase(uuid, text),
              public.supplier_outstanding(uuid, uuid[]) to authenticated;
