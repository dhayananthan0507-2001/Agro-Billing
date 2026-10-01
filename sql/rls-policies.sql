-- Agro POS — Phase 1 RLS. Run after database-schema.sql.
-- Clients never INSERT companies/profiles directly: only create_company_and_owner() does.
alter table public.companies        enable row level security;
alter table public.profiles         enable row level security;
alter table public.company_members  enable row level security;
alter table public.company_settings enable row level security;
alter table public.audit_logs       enable row level security;

create policy companies_select on public.companies for select to authenticated using (public.is_member(id));
create policy companies_update on public.companies for update to authenticated
  using (public.has_role(id, array['owner'])) with check (public.has_role(id, array['owner']));

create policy profiles_select on public.profiles for select to authenticated using (
  id = auth.uid() or exists (select 1 from company_members a join company_members b on a.company_id = b.company_id
    where a.user_id = auth.uid() and b.user_id = profiles.id));
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create policy members_select on public.company_members for select to authenticated using (public.is_member(company_id));
create policy members_owner_write on public.company_members for all to authenticated
  using (public.has_role(company_id, array['owner'])) with check (public.has_role(company_id, array['owner']));

create policy settings_select on public.company_settings for select to authenticated using (public.is_member(company_id));
create policy settings_update on public.company_settings for update to authenticated
  using (public.has_role(company_id, array['owner'])) with check (public.has_role(company_id, array['owner']));

create policy audit_select on public.audit_logs for select to authenticated
  using (public.has_role(company_id, array['owner','manager']));
create policy audit_insert on public.audit_logs for insert to authenticated
  with check (public.is_member(company_id) and user_id = auth.uid());
-- No UPDATE/DELETE policy on audit_logs: entries are append-only.
