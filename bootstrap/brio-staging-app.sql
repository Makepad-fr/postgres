\set ON_ERROR_STOP on

-- Run with a PostgreSQL superuser connection. This creates the staging-only
-- Brio application role/database pair without embedding credentials.

\if :{?brio_staging_app_password}
\else
  \echo 'missing required psql variable: brio_staging_app_password'
  SELECT 1 / 0;
\endif

\if :{?brio_staging_backup_password}
\else
  \echo 'missing required psql variable: brio_staging_backup_password'
  SELECT 1 / 0;
\endif

SELECT CASE WHEN NULLIF(btrim(:'brio_staging_app_password'), '') IS NULL THEN 'false' ELSE 'true' END AS brio_staging_app_password_is_nonempty \gset
\if :brio_staging_app_password_is_nonempty
\else
  \echo 'empty required psql variable: brio_staging_app_password'
  SELECT 1 / 0;
\endif

SELECT CASE WHEN NULLIF(btrim(:'brio_staging_backup_password'), '') IS NULL THEN 'false' ELSE 'true' END AS brio_staging_backup_password_is_nonempty \gset
\if :brio_staging_backup_password_is_nonempty
\else
  \echo 'empty required psql variable: brio_staging_backup_password'
  SELECT 1 / 0;
\endif

SELECT CASE
  WHEN inet_client_addr() IS NULL OR coalesce((SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()), false)
  THEN 'true' ELSE 'false'
END AS brio_staging_bootstrap_transport_is_secure \gset
\if :brio_staging_bootstrap_transport_is_secure
\else
  \echo 'Brio staging bootstrap refuses a remote plaintext PostgreSQL session'
  SELECT 1 / 0;
\endif

SELECT pg_advisory_lock(hashtext('makepad-postgres'), hashtext('brio-staging-app-bootstrap'));

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'brio_staging_app') THEN
    CREATE ROLE brio_staging_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'brio_staging_backup') THEN
    CREATE ROLE brio_staging_backup LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
  END IF;
END;
$$;
ALTER ROLE brio_staging_app LOGIN PASSWORD :'brio_staging_app_password';
ALTER ROLE brio_staging_app NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE brio_staging_backup LOGIN PASSWORD :'brio_staging_backup_password';
ALTER ROLE brio_staging_backup NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 2;
SELECT 'CREATE DATABASE brio_staging OWNER brio_staging_app'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'brio_staging') \gexec
SELECT 'ALTER DATABASE brio_staging OWNER TO brio_staging_app'
WHERE EXISTS (
  SELECT 1
  FROM pg_database d
  JOIN pg_roles r ON r.oid = d.datdba
  WHERE d.datname = 'brio_staging'
    AND r.rolname <> 'brio_staging_app'
) \gexec
REVOKE ALL ON DATABASE brio_staging FROM PUBLIC;
REVOKE ALL ON DATABASE brio_staging FROM brio_staging_backup;
GRANT CONNECT ON DATABASE brio_staging TO brio_staging_app;
GRANT CONNECT ON DATABASE brio_staging TO brio_staging_backup;
ALTER ROLE brio_staging_backup IN DATABASE brio_staging SET default_transaction_read_only TO on;

SELECT pg_advisory_unlock(hashtext('makepad-postgres'), hashtext('brio-staging-app-bootstrap'));

\connect brio_staging
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO brio_staging_backup;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO brio_staging_backup;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO brio_staging_backup;
ALTER DEFAULT PRIVILEGES FOR ROLE brio_staging_app IN SCHEMA public GRANT SELECT ON TABLES TO brio_staging_backup;
ALTER DEFAULT PRIVILEGES FOR ROLE brio_staging_app IN SCHEMA public GRANT SELECT ON SEQUENCES TO brio_staging_backup;
