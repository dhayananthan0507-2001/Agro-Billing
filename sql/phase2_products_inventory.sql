-- Agro POS — Phase 2: categories, products, inventory, batches, movements.
-- Additive only. Reuses Phase 1: is_member(), has_role(), company_members, company_settings.
do $$ begin
  if to_regclass('public.company_members') is null or to_regprocedure('public.is_member(uuid)') is null
     or to_regprocedure('public.has_role(uuid,text[])') is null then
    raise exception 'Phase 1 not found. Run database-schema.sql and rls-policies.sql first.';
  end if;
end $$;

create or replace function public.touch_updated_at() returns trigger language plpgsql as
$$ begin new.updated_at = now(); return new; end $$;

create table if not exists public.categories (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  description text,
  status text not null default 'active' check (status in ('active','archived')),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique (id, company_id));
create unique index if not exists categories_company_name_uq on public.categories(company_id, lower(name));

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  category_id uuid not null,
  product_name text not null check (length(trim(product_name)) > 0),
  product_code text, sku text, barcode text, brand text, description text,
  unit text not null check (length(trim(unit)) > 0),
  purchase_price numeric(12,2) not null default 0 check (purchase_price >= 0),
  selling_price  numeric(12,2) not null default 0 check (selling_price  >= 0),
  mrp            numeric(12,2) not null default 0 check (mrp >= 0),
  tax_rate       numeric(5,2)  not null default 0 check (tax_rate >= 0),
  minimum_stock  numeric(12,3) not null default 0 check (minimum_stock >= 0),
  product_image_url text,
  is_active boolean not null default true,
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique (id, company_id),
  foreign key (category_id, company_id) references public.categories(id, company_id));
create unique index if not exists products_company_sku_uq     on public.products(company_id, lower(sku))          where sku is not null;
create unique index if not exists products_company_barcode_uq on public.products(company_id, barcode)             where barcode is not null;
create unique index if not exists products_company_code_uq    on public.products(company_id, lower(product_code)) where product_code is not null;
create index if not exists products_company_name_idx on public.products(company_id, lower(product_name));
create index if not exists products_company_cat_idx  on public.products(company_id, category_id);
create index if not exists products_company_created_idx on public.products(company_id, created_at desc);

create table if not exists public.inventory (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  product_id uuid not null,
  quantity numeric(14,3) not null default 0 check (quantity >= 0),
  updated_at timestamptz not null default now(),
  unique (company_id, product_id),
  foreign key (product_id, company_id) references public.products(id, company_id) on delete cascade);

create table if not exists public.product_batches (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  product_id uuid not null,
  batch_number text not null check (length(trim(batch_number)) > 0),
  manufacturing_date date, expiry_date date,
  quantity numeric(14,3) not null default 0 check (quantity >= 0),
  purchase_price numeric(12,2) check (purchase_price >= 0),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique (id, company_id),
  unique (company_id, product_id, batch_number),
  check (expiry_date is null or manufacturing_date is null or expiry_date >= manufacturing_date),
  foreign key (product_id, company_id) references public.products(id, company_id) on delete cascade);
create index if not exists batches_company_expiry_idx on public.product_batches(company_id, expiry_date);
create index if not exists batches_product_idx on public.product_batches(product_id);

create table if not exists public.inventory_movements (
  id bigint generated always as identity primary key,
  company_id uuid not null references public.companies(id) on delete cascade,
  product_id uuid not null, batch_id uuid,
  movement_type text not null check (movement_type in
    ('opening','purchase','sale','sale_return','purchase_return','damage','adjustment')),
  quantity numeric(14,3) not null check (quantity <> 0),            -- signed: + in, - out
  previous_quantity numeric(14,3) not null, new_quantity numeric(14,3) not null check (new_quantity >= 0),
  reference_type text, reference_id text, notes text,
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now(),
  foreign key (product_id, company_id) references public.products(id, company_id));
create index if not exists movements_company_product_idx on public.inventory_movements(company_id, product_id, created_at desc);

do $$ declare t text; begin
  foreach t in array array['categories','products','product_batches'] loop
    execute format('drop trigger if exists %I_touch on public.%I', t, t);
    execute format('create trigger %I_touch before update on public.%I for each row execute function public.touch_updated_at()', t, t);
  end loop; end $$;

-- ---------- RLS ----------
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.inventory enable row level security;
alter table public.product_batches enable row level security;
alter table public.inventory_movements enable row level security;

do $$ declare t text; begin
  foreach t in array array['categories','products','inventory','product_batches','inventory_movements'] loop
    execute format('drop policy if exists %I_select on public.%I', t, t);
    execute format('create policy %I_select on public.%I for select to authenticated using (public.is_member(company_id))', t, t);
  end loop; end $$;

-- Owner/manager may write catalogue data directly. No DELETE policy: archive instead.
drop policy if exists categories_insert on public.categories;
drop policy if exists categories_update on public.categories;
drop policy if exists products_insert on public.products;
drop policy if exists products_update on public.products;
create policy categories_insert on public.categories for insert to authenticated with check (public.has_role(company_id, array['owner','manager']));
create policy categories_update on public.categories for update to authenticated
  using (public.has_role(company_id, array['owner','manager'])) with check (public.has_role(company_id, array['owner','manager']));
create policy products_insert on public.products for insert to authenticated with check (public.has_role(company_id, array['owner','manager']));
create policy products_update on public.products for update to authenticated
  using (public.has_role(company_id, array['owner','manager'])) with check (public.has_role(company_id, array['owner','manager']));
-- inventory / batches / movements: NO client write policies. Changes only via the RPCs below.

-- ---------- RPC: create product + opening stock, atomically ----------
create or replace function public.create_product(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare cid uuid := (p->>'company_id')::uuid; pid uuid; opening numeric := coalesce((p->>'opening_stock')::numeric, 0);
begin
  if not has_role(cid, array['owner','manager']) then raise exception 'NOT_ALLOWED'; end if;
  if opening < 0 then raise exception 'INVALID_QUANTITY'; end if;
  insert into products(company_id, category_id, product_name, product_code, sku, barcode, brand, description, unit,
      purchase_price, selling_price, mrp, tax_rate, minimum_stock)
  values (cid, (p->>'category_id')::uuid, trim(p->>'product_name'), nullif(trim(p->>'product_code'),''), nullif(trim(p->>'sku'),''),
      nullif(trim(p->>'barcode'),''), nullif(trim(p->>'brand'),''), nullif(trim(p->>'description'),''), p->>'unit',
      coalesce((p->>'purchase_price')::numeric,0), coalesce((p->>'selling_price')::numeric,0), coalesce((p->>'mrp')::numeric,0),
      coalesce((p->>'tax_rate')::numeric,0), coalesce((p->>'minimum_stock')::numeric,0))
  returning id into pid;
  insert into inventory(company_id, product_id, quantity) values (cid, pid, opening);
  if opening > 0 then
    insert into product_batches(company_id, product_id, batch_number, quantity, purchase_price)
      values (cid, pid, 'OPENING', opening, coalesce((p->>'purchase_price')::numeric,0));
    insert into inventory_movements(company_id, product_id, batch_id, movement_type, quantity, previous_quantity, new_quantity, notes)
      select cid, pid, id, 'opening', opening, 0, opening, 'Opening stock' from product_batches where product_id = pid and batch_number = 'OPENING';
  end if;
  return pid;
end $$;

-- ---------- RPC: stock adjustment (inventory + batch + movement, one transaction) ----------
-- p_kind: 'increase' | 'decrease' | 'damage'. Inventory total = sum of batch quantities.
create or replace function public.adjust_stock(p_product uuid, p_batch uuid, p_kind text, p_qty numeric, p_notes text default null)
returns numeric language plpgsql security definer set search_path = public as $$
declare cid uuid; b product_batches; inv inventory; delta numeric;
begin
  select company_id into cid from products where id = p_product;
  if cid is null or not has_role(cid, array['owner','manager']) then raise exception 'NOT_ALLOWED'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'INVALID_QUANTITY'; end if;
  if p_kind not in ('increase','decrease','damage') then raise exception 'INVALID_TYPE'; end if;
  select * into b from product_batches where id = p_batch and product_id = p_product and company_id = cid for update;
  if not found then raise exception 'BATCH_NOT_FOUND'; end if;
  select * into inv from inventory where product_id = p_product and company_id = cid for update;
  delta := case when p_kind = 'increase' then p_qty else -p_qty end;
  if b.quantity + delta < 0 then raise exception 'INSUFFICIENT_STOCK'; end if;
  update product_batches set quantity = quantity + delta where id = b.id;
  update inventory set quantity = quantity + delta, updated_at = now() where id = inv.id;
  insert into inventory_movements(company_id, product_id, batch_id, movement_type, quantity, previous_quantity, new_quantity, notes)
    values (cid, p_product, b.id, case when p_kind = 'damage' then 'damage' else 'adjustment' end, delta, inv.quantity, inv.quantity + delta, p_notes);
  return inv.quantity + delta;
end $$;

-- ---------- Dashboard metrics (SECURITY INVOKER: RLS applies) ----------
create or replace function public.dashboard_stats(p_company uuid) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object(
    'products',   (select count(*) from products where company_id = p_company and is_active),
    'categories', (select count(*) from categories where company_id = p_company and status = 'active'),
    'low_stock',  (select count(*) from products p join inventory i on i.product_id = p.id where p.company_id = p_company and p.is_active and i.quantity > 0 and i.quantity <= p.minimum_stock),
    'out_of_stock',(select count(*) from products p join inventory i on i.product_id = p.id where p.company_id = p_company and p.is_active and i.quantity = 0),
    'expiring',   (select count(*) from product_batches b where b.company_id = p_company and b.quantity > 0 and b.expiry_date is not null
                    and b.expiry_date <= current_date + coalesce((select expiry_alert_days from company_settings where company_id = p_company), 30)),
    'stock_value',(select coalesce(sum(i.quantity * p.purchase_price), 0) from products p join inventory i on i.product_id = p.id where p.company_id = p_company and p.is_active)) $$;

revoke all on function public.create_product(jsonb), public.adjust_stock(uuid,uuid,text,numeric,text) from public, anon;
grant execute on function public.create_product(jsonb), public.adjust_stock(uuid,uuid,text,numeric,text), public.dashboard_stats(uuid) to authenticated;
