-- Agro POS — Phase 1 schema (auth, companies, roles, settings, audit). Run first.
create extension if not exists pgcrypto;

create table public.companies (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) > 0),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text, mobile text,
  created_at timestamptz not null default now()
);
create table public.company_members (
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('owner','manager','cashier')),
  created_at timestamptz not null default now(),
  primary key (company_id, user_id)
);
create index company_members_user_idx on public.company_members(user_id);

create table public.company_settings (
  company_id uuid primary key references public.companies(id) on delete cascade,
  shop_name text, address text, phone text, email text, gst_number text,
  invoice_prefix text not null default 'INV',
  currency text not null default 'INR',
  invoice_footer text not null default 'Thank you for your business',
  low_stock_threshold int not null default 10,
  expiry_alert_days int not null default 30,
  allow_negative_stock boolean not null default false,
  updated_at timestamptz not null default now()
);
create table public.audit_logs (
  id bigint generated always as identity primary key,
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid references auth.users(id),
  action text not null, record_type text, record_id text, details jsonb,
  created_at timestamptz not null default now()
);
create index audit_logs_company_created_idx on public.audit_logs(company_id, created_at desc);

-- Helpers used by every RLS policy (security definer avoids policy recursion).
create or replace function public.is_member(cid uuid) returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from company_members where company_id = cid and user_id = auth.uid()) $$;

create or replace function public.has_role(cid uuid, roles text[]) returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from company_members where company_id = cid and user_id = auth.uid() and role = any(roles)) $$;

-- Registration: creates company + owner membership + profile + settings. Idempotent.
create or replace function public.create_company_and_owner(p_company_name text, p_owner_name text, p_mobile text)
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); cid uuid;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if length(trim(coalesce(p_company_name,''))) = 0 then raise exception 'Company name is required'; end if;
  select company_id into cid from company_members where user_id = uid limit 1;
  if cid is not null then return cid; end if;
  insert into companies(name, created_by) values (trim(p_company_name), uid) returning id into cid;
  insert into company_members(company_id, user_id, role) values (cid, uid, 'owner');
  insert into profiles(id, full_name, mobile) values (uid, p_owner_name, p_mobile)
    on conflict (id) do update set full_name = excluded.full_name, mobile = excluded.mobile;
  insert into company_settings(company_id, shop_name) values (cid, trim(p_company_name));
  insert into audit_logs(company_id, user_id, action, record_type, record_id)
    values (cid, uid, 'company_created', 'company', cid::text);
  return cid;
end $$;
revoke all on function public.create_company_and_owner(text,text,text) from public, anon;
grant execute on function public.create_company_and_owner(text,text,text) to authenticated;
