-- ============================================================================
-- 014_supabase_hardening.sql
--
-- Purpose: remove the privileges Supabase grants by default to its Data API
--          roles. The application never uses them: it connects as its own
--          login role and switches to parking_admin / parking_operator /
--          parking_customer per request (see api/db.py).
--
-- Why it matters: Supabase's default privileges give `anon` and
-- `authenticated` ALL on every table created in `public`, including TRUNCATE.
-- Row-level security filters SELECT/INSERT/UPDATE/DELETE, but TRUNCATE is not
-- subject to RLS at all, and the reference tables (facility, slot, tariff...)
-- have no RLS. Anyone holding the project's anon key could therefore edit or
-- empty them through the auto-generated REST API.
--
-- On a plain PostgreSQL install these roles do not exist and this file does
-- nothing. Idempotent.
-- ============================================================================
DO $$
DECLARE
    r TEXT;
BEGIN
    FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM %I', r);
            EXECUTE format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM %I', r);
            EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES    FROM %I', r);
            EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON SEQUENCES FROM %I', r);
            RAISE NOTICE 'Revoked Data API access for role %', r;
        END IF;
    END LOOP;
END $$;
