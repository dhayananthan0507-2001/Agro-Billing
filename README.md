# Agro POS — Phase 1 (auth, database, company isolation)
1. Supabase → SQL Editor: run `sql/database-schema.sql`, then `sql/rls-policies.sql`.
2. Put your Project URL and anon key in `assets/js/auth.js`.
3. Supabase → Authentication → URL Configuration: add your site URL (GitHub Pages URL) as Site URL / redirect.
4. Upload this folder's contents to the repo root (index.html, login.html, register.html, assets/, sql/).
`dashboard.html` is not built yet (Phase 2+), so a successful login currently lands on a 404.
