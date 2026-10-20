-- One-time bootstrap of the FIRST super administrator.
-- 1. Create the user in Supabase Dashboard > Authentication > Users (strong password, MFA recommended).
-- 2. Run this in the SQL editor (runs as the database owner) or via psql with the DB connection string:
--      psql "$SUPABASE_DB_URL" -v email="'you@company.com'" -f scripts/bootstrap-admin.sql
-- It refuses to run once a super_admin exists. Further staff are added in the admin portal (Roles & staff).
select public.bootstrap_first_admin(:email);
