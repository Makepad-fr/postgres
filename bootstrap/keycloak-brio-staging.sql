\set ON_ERROR_STOP on

-- Run with a PostgreSQL superuser connection. This creates only the
-- staging-only Brio Keycloak role/database pair and never rotates credentials
-- for another Keycloak realm.

\if :{?keycloak_brio_staging_app_password}
\else
  \echo 'missing required psql variable: keycloak_brio_staging_app_password'
  SELECT 1 / 0;
\endif

\if :{?keycloak_brio_staging_backup_password}
\else
  \echo 'missing required psql variable: keycloak_brio_staging_backup_password'
  SELECT 1 / 0;
\endif

SELECT CASE WHEN NULLIF(btrim(:'keycloak_brio_staging_app_password'), '') IS NULL THEN 'false' ELSE 'true' END AS keycloak_brio_staging_app_password_is_nonempty \gset
\if :keycloak_brio_staging_app_password_is_nonempty
\else
  \echo 'empty required psql variable: keycloak_brio_staging_app_password'
  SELECT 1 / 0;
\endif

SELECT CASE WHEN NULLIF(btrim(:'keycloak_brio_staging_backup_password'), '') IS NULL THEN 'false' ELSE 'true' END AS keycloak_brio_staging_backup_password_is_nonempty \gset
\if :keycloak_brio_staging_backup_password_is_nonempty
\else
  \echo 'empty required psql variable: keycloak_brio_staging_backup_password'
  SELECT 1 / 0;
\endif

SELECT CASE
  WHEN inet_client_addr() IS NULL OR coalesce((SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()), false)
  THEN 'true' ELSE 'false'
END AS keycloak_brio_staging_bootstrap_transport_is_secure \gset
\if :keycloak_brio_staging_bootstrap_transport_is_secure
\else
  \echo 'Brio Keycloak bootstrap refuses a remote plaintext PostgreSQL session'
  SELECT 1 / 0;
\endif

SELECT pg_advisory_lock(hashtext('makepad-postgres'), hashtext('keycloak-brio-staging-bootstrap'));

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'keycloak_brio_staging_app') THEN
    CREATE ROLE keycloak_brio_staging_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'keycloak_brio_staging_backup') THEN
    CREATE ROLE keycloak_brio_staging_backup LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
  END IF;
END;
$$;
ALTER ROLE keycloak_brio_staging_app LOGIN PASSWORD :'keycloak_brio_staging_app_password';
ALTER ROLE keycloak_brio_staging_app NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE keycloak_brio_staging_backup LOGIN PASSWORD :'keycloak_brio_staging_backup_password';
ALTER ROLE keycloak_brio_staging_backup NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 2;
SELECT 'CREATE DATABASE keycloak_brio_staging OWNER keycloak_brio_staging_app'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'keycloak_brio_staging') \gexec
SELECT 'ALTER DATABASE keycloak_brio_staging OWNER TO keycloak_brio_staging_app'
WHERE EXISTS (
  SELECT 1
  FROM pg_database d
  JOIN pg_roles r ON r.oid = d.datdba
  WHERE d.datname = 'keycloak_brio_staging'
    AND r.rolname <> 'keycloak_brio_staging_app'
) \gexec
REVOKE ALL ON DATABASE keycloak_brio_staging FROM PUBLIC;
REVOKE ALL ON DATABASE keycloak_brio_staging FROM keycloak_brio_staging_backup;
GRANT CONNECT ON DATABASE keycloak_brio_staging TO keycloak_brio_staging_app;
GRANT CONNECT ON DATABASE keycloak_brio_staging TO keycloak_brio_staging_backup;
ALTER ROLE keycloak_brio_staging_backup IN DATABASE keycloak_brio_staging SET default_transaction_read_only TO on;

SELECT pg_advisory_unlock(hashtext('makepad-postgres'), hashtext('keycloak-brio-staging-bootstrap'));

\connect keycloak_brio_staging
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO keycloak_brio_staging_backup;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO keycloak_brio_staging_backup;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO keycloak_brio_staging_backup;
ALTER DEFAULT PRIVILEGES FOR ROLE keycloak_brio_staging_app IN SCHEMA public GRANT SELECT ON TABLES TO keycloak_brio_staging_backup;
ALTER DEFAULT PRIVILEGES FOR ROLE keycloak_brio_staging_app IN SCHEMA public GRANT SELECT ON SEQUENCES TO keycloak_brio_staging_backup;
