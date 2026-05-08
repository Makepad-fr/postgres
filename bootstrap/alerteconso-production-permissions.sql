\set ON_ERROR_STOP on

-- Run this repair with a PostgreSQL superuser connection to the
-- alerteconso_production database. It fixes objects that were created by the
-- postgres superuser instead of the application owner.

SELECT pg_advisory_lock(hashtext('makepad-postgres'), hashtext('alerteconso-production-permissions'));

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'alerteconso_production_app') THEN
    RAISE EXCEPTION 'missing required role: alerteconso_production_app';
  END IF;

  IF current_database() <> 'alerteconso_production' THEN
    RAISE EXCEPTION 'connect to alerteconso_production before running this repair';
  END IF;

  IF to_regclass('public.recalls') IS NULL THEN
    RAISE EXCEPTION 'missing required table: public.recalls';
  END IF;
END;
$$;

ALTER DATABASE alerteconso_production OWNER TO alerteconso_production_app;
GRANT CONNECT ON DATABASE alerteconso_production TO alerteconso_production_app;

ALTER SCHEMA public OWNER TO alerteconso_production_app;
GRANT USAGE, CREATE ON SCHEMA public TO alerteconso_production_app;

ALTER TABLE public.recalls OWNER TO alerteconso_production_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.recalls TO alerteconso_production_app;

GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO alerteconso_production_app;

ALTER DEFAULT PRIVILEGES FOR ROLE alerteconso_production_app IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO alerteconso_production_app;
ALTER DEFAULT PRIVILEGES FOR ROLE alerteconso_production_app IN SCHEMA public
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO alerteconso_production_app;

SELECT pg_advisory_unlock(hashtext('makepad-postgres'), hashtext('alerteconso-production-permissions'));
