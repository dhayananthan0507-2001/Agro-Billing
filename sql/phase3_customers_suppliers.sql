-- Agro POS — Phase 3: customers & suppliers.
-- ADDITIVE ONLY. Safe to run on the live project: it creates new objects and never touches
-- Phase 1/2 tables, policies or functions. Safe to re-run (everything is "if not exists" /
-- "or replace"; only the Phase 3 policies/triggers created below are dropped and re-created).
--
-- Reuses from Phase 1:  public.companies, public.is_member(uuid), public.has_role(uuid, text[]).
-- Terminology: this app's tenant column is `company_id` (NOT `shop_id`) and roles live in
-- company_members.role ('owner' | 'manager' | 'cashier'). Phase 3 follows the same.
--
-- Balance convention (no earlier convention existed, so it is defined here):
--   opening_balance is always >= 0; balance_type says which direction it runs.
--   customers : 'debit'  = customer owes the shop (receivable)  [default]
--               'credit' = shop owes the customer (advance paid by customer)
--   suppliers : 'credit' = shop owes the supplier (payable)     [default]
--               'debit'  = supplier owes the shop (advance paid to supplier)

do $$ begin
  if to_regclass('public.companies') is null
     or to_regclass('public.company_members') is null
     or to_regprocedure('public.is_member(uuid)') is null
     or to_regprocedure('public.has_role(uuid,text[])') is null then
    raise exception 'Phase 1 not found. Run database-schema.sql and rls-policies.sql first.';
  end if;
end $$;

-- ---------- Tables ----------
create table if not exists public.customers (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  customer_name text not null check (char_length(btrim(customer_name)) between 1 and 150),
  phone text not null check (phone ~ '^\+?[0-9]{10,13}$'),
  email text check (email is null or (char_length(email) <= 254 and email ~ '^[^\s@]+@[^\s@]+\.[^\s@]+$')),
  address text check (address is null or char_length(address) <= 500),
  city text check (city is null or char_length(city) <= 100),
  state text check (state is null or char_length(state) <= 100),
  pincode text check (pincode is null or pincode ~ '^[1-9][0-9]{5}$'),
  gst_number text check (gst_number is null or gst_number ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'),
  opening_balance numeric(14,2) not null default 0 check (opening_balance >= 0),
  balance_type text not null default 'debit' check (balance_type in ('credit','debit')),
  notes text check (notes is null or char_length(notes) <= 1000),
  is_active boolean not null default true,
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, company_id));   -- lets Phase 4+ tables (sales, receipts) use a same-company composite FK

create table if not exists public.suppliers (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  supplier_name text not null check (char_length(btrim(supplier_name)) between 1 and 150),
  phone text not null check (phone ~ '^\+?[0-9]{10,13}$'),
  email text check (email is null or (char_length(email) <= 254 and email ~ '^[^\s@]+@[^\s@]+\.[^\s@]+$')),
  address text check (address is null or char_length(address) <= 500),
  city text check (city is null or char_length(city) <= 100),
  state text check (state is null or char_length(state) <= 100),
  pincode text check (pincode is null or pincode ~ '^[1-9][0-9]{5}$'),
  gst_number text check (gst_number is null or gst_number ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'),
  opening_balance numeric(14,2) not null default 0 check (opening_balance >= 0),
  balance_type text not null default 'credit' check (balance_type in ('credit','debit')),
  notes text check (notes is null or char_length(notes) <= 1000),
  is_active boolean not null default true,
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, company_id));

-- ---------- Indexes (every query is company-scoped, so company_id leads) ----------
-- List page: WHERE company_id AND is_active ORDER BY name  -> one index serves filter + sort.
create index if not exists customers_company_active_name_idx on public.customers(company_id, is_active, customer_name);
create index if not exists suppliers_company_active_name_idx on public.suppliers(company_id, is_active, supplier_name);
create index if not exists customers_company_phone_idx on public.customers(company_id, phone);
create index if not exists suppliers_company_phone_idx on public.suppliers(company_id, phone);
-- A GSTIN identifies one taxpayer: block accidental duplicates inside one shop (blank GST is fine).
create unique index if not exists customers_company_gst_uq on public.customers(company_id, gst_number) where gst_number is not null;
create unique index if not exists suppliers_company_gst_uq on public.suppliers(company_id, gst_number) where gst_number is not null;

-- ---------- Trigger: normalise input + lock tenant/ownership columns ----------
-- Runs BEFORE the CHECK constraints, so " 98765 43210 " / "27aabcu9603r1zx" are cleaned first.
-- On UPDATE it makes company_id, created_by and created_at immutable, whatever the client sends.
create or replace function public.party_before_write() returns trigger language plpgsql as $$
begin
  new.phone      := nullif(regexp_replace(coalesce(new.phone, ''), '[\s()-]', '', 'g'), '');
  new.email      := lower(nullif(btrim(new.email), ''));
  new.gst_number := upper(nullif(btrim(new.gst_number), ''));
  new.address    := nullif(btrim(new.address), '');
  new.city       := nullif(btrim(new.city), '');
  new.state      := nullif(btrim(new.state), '');
  new.pincode    := nullif(btrim(new.pincode), '');
  new.notes      := nullif(btrim(new.notes), '');
  if tg_op = 'UPDATE' then
    if new.company_id is distinct from old.company_id then raise exception 'COMPANY_IMMUTABLE'; end if;
    new.created_by := old.created_by;
    new.created_at := old.created_at;
    new.updated_at := now();
  end if;
  return new;
end $$;

drop trigger if exists customers_before_write on public.customers;
create trigger customers_before_write before insert or update on public.customers
  for each row execute function public.party_before_write();
drop trigger if exists suppliers_before_write on public.suppliers;
create trigger suppliers_before_write before insert or update on public.suppliers
  for each row execute function public.party_before_write();

-- ---------- RLS ----------
alter table public.customers enable row level security;
alter table public.suppliers enable row level security;

-- Table privileges: signed-in users only, and never DELETE (records are deactivated, not erased).
revoke all on public.customers from anon, authenticated;
revoke all on public.suppliers from anon, authenticated;
grant select, insert, update on public.customers to authenticated;
grant select, insert, update on public.suppliers to authenticated;

do $$ declare t text; begin
  foreach t in array array['customers','suppliers'] loop
    execute format('drop policy if exists %I_select on public.%I', t, t);
    execute format('drop policy if exists %I_insert on public.%I', t, t);
    execute format('drop policy if exists %I_update on public.%I', t, t);
    -- Any member of the company can read (owner, manager, cashier).
    execute format('create policy %I_select on public.%I for select to authenticated using (public.is_member(company_id))', t, t);
    -- Only owner/manager can write, and only inside their own company. Same rule as products.
    execute format($f$create policy %I_insert on public.%I for insert to authenticated
      with check (public.has_role(company_id, array['owner','manager']) and (created_by is null or created_by = auth.uid()))$f$, t, t);
    execute format($f$create policy %I_update on public.%I for update to authenticated
      using (public.has_role(company_id, array['owner','manager']))
      with check (public.has_role(company_id, array['owner','manager']))$f$, t, t);
    -- Deliberately NO delete policy.
  end loop;
end $$;

-- ---------- Dashboard counters (SECURITY INVOKER: RLS applies, so another company's id returns zeros) ----------
create or replace function public.party_stats(p_company uuid) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object(
    'customers',         (select count(*) from customers where company_id = p_company),
    'active_customers',  (select count(*) from customers where company_id = p_company and is_active),
    'suppliers',         (select count(*) from suppliers where company_id = p_company),
    'active_suppliers',  (select count(*) from suppliers where company_id = p_company and is_active)) $$;

revoke all on function public.party_stats(uuid) from public, anon;
grant execute on function public.party_stats(uuid) to authenticated;
