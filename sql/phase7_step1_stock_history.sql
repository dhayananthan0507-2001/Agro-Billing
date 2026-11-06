-- Agro POS — Phase 7, Step 1: Stock History.
-- Adds ONE index so the history page (newest movements first, per shop) stays fast as the movement log grows.
-- Nothing existing is changed, no data is touched, no function is replaced. Safe to run more than once.
-- (The later full Phase 7 migration contains the same statement; running both is harmless.)
create index if not exists movements_company_date_idx on public.inventory_movements(company_id, created_at desc, id desc);
