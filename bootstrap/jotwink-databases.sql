\set ON_ERROR_STOP on

-- Run this bootstrap with a PostgreSQL superuser connection. It provisions
-- the Jotwink product and Keycloak databases without embedding credentials.

\if :{?jotwink_app_password}
\else
  \echo 'missing required psql variable: jotwink_app_password'
  \quit 1
\endif
\if :{?keycloak_jotwink_app_password}
\else
  \echo 'missing required psql variable: keycloak_jotwink_app_password'
  \quit 1
\endif

SELECT CASE WHEN NULLIF(btrim(:'jotwink_app_password'), '') IS NULL THEN 'false' ELSE 'true' END AS jotwink_app_password_is_nonempty \gset
\if :jotwink_app_password_is_nonempty
\else
  \echo 'empty required psql variable: jotwink_app_password'
  \quit 1
\endif
SELECT CASE WHEN NULLIF(btrim(:'keycloak_jotwink_app_password'), '') IS NULL THEN 'false' ELSE 'true' END AS keycloak_jotwink_app_password_is_nonempty \gset
\if :keycloak_jotwink_app_password_is_nonempty
\else
  \echo 'empty required psql variable: keycloak_jotwink_app_password'
  \quit 1
\endif

SELECT pg_advisory_lock(hashtext('makepad-postgres'), hashtext('jotwink-databases-bootstrap'));

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'jotwink_app') THEN
    CREATE ROLE jotwink_app LOGIN;
  END IF;
END;
$$;
ALTER ROLE jotwink_app LOGIN PASSWORD :'jotwink_app_password';
SELECT 'CREATE DATABASE jotwink OWNER jotwink_app'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'jotwink') \gexec
SELECT 'ALTER DATABASE jotwink OWNER TO jotwink_app'
WHERE EXISTS (
  SELECT 1
  FROM pg_database d
  JOIN pg_roles r ON r.oid = d.datdba
  WHERE d.datname = 'jotwink'
    AND r.rolname <> 'jotwink_app'
) \gexec
GRANT CONNECT ON DATABASE jotwink TO jotwink_app;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'keycloak_jotwink_app') THEN
    CREATE ROLE keycloak_jotwink_app LOGIN;
  END IF;
END;
$$;
ALTER ROLE keycloak_jotwink_app LOGIN PASSWORD :'keycloak_jotwink_app_password';
SELECT 'CREATE DATABASE keycloak_jotwink OWNER keycloak_jotwink_app'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'keycloak_jotwink') \gexec
SELECT 'ALTER DATABASE keycloak_jotwink OWNER TO keycloak_jotwink_app'
WHERE EXISTS (
  SELECT 1
  FROM pg_database d
  JOIN pg_roles r ON r.oid = d.datdba
  WHERE d.datname = 'keycloak_jotwink'
    AND r.rolname <> 'keycloak_jotwink_app'
) \gexec
GRANT CONNECT ON DATABASE keycloak_jotwink TO keycloak_jotwink_app;

SELECT pg_advisory_unlock(hashtext('makepad-postgres'), hashtext('jotwink-databases-bootstrap'));
