\set ON_ERROR_STOP on

-- Run this bootstrap with a PostgreSQL superuser connection. It creates roles,
-- sets passwords, creates databases, and assigns database ownership.
-- The advisory lock serializes concurrent bootstrap runs after local psql
-- variable validation because PostgreSQL does not support CREATE DATABASE
-- inside PL/pgSQL exception blocks.

\if :{?keycloak_vif_app_password}
\else
  \echo 'missing required psql variable: keycloak_vif_app_password'
  \quit 1
\endif

SELECT CASE WHEN NULLIF(btrim(:'keycloak_vif_app_password'), '') IS NULL THEN 'false' ELSE 'true' END AS keycloak_vif_app_password_is_nonempty \gset
\if :keycloak_vif_app_password_is_nonempty
\else
  \echo 'empty required psql variable: keycloak_vif_app_password'
  \quit 1
\endif

\if :{?keycloak_makepad_app_password}
\else
  \echo 'missing required psql variable: keycloak_makepad_app_password'
  \quit 1
\endif

SELECT CASE WHEN NULLIF(btrim(:'keycloak_makepad_app_password'), '') IS NULL THEN 'false' ELSE 'true' END AS keycloak_makepad_app_password_is_nonempty \gset
\if :keycloak_makepad_app_password_is_nonempty
\else
  \echo 'empty required psql variable: keycloak_makepad_app_password'
  \quit 1
\endif

\if :{?keycloak_vestiaire_app_password}
\else
  \echo 'missing required psql variable: keycloak_vestiaire_app_password'
  \quit 1
\endif

SELECT CASE WHEN NULLIF(btrim(:'keycloak_vestiaire_app_password'), '') IS NULL THEN 'false' ELSE 'true' END AS keycloak_vestiaire_app_password_is_nonempty \gset
\if :keycloak_vestiaire_app_password_is_nonempty
\else
  \echo 'empty required psql variable: keycloak_vestiaire_app_password'
  \quit 1
\endif

SELECT pg_advisory_lock(hashtext('makepad-postgres'), hashtext('keycloak-bootstrap'));

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'keycloak_vif_app') THEN
    CREATE ROLE keycloak_vif_app LOGIN;
  END IF;
END;
$$;
ALTER ROLE keycloak_vif_app LOGIN PASSWORD :'keycloak_vif_app_password';
SELECT 'CREATE DATABASE keycloak_vif OWNER keycloak_vif_app'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'keycloak_vif') \gexec
SELECT 'ALTER DATABASE keycloak_vif OWNER TO keycloak_vif_app'
WHERE EXISTS (
  SELECT 1
  FROM pg_database d
  JOIN pg_roles r ON r.oid = d.datdba
  WHERE d.datname = 'keycloak_vif'
    AND r.rolname <> 'keycloak_vif_app'
) \gexec
GRANT CONNECT ON DATABASE keycloak_vif TO keycloak_vif_app;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'keycloak_makepad_app') THEN
    CREATE ROLE keycloak_makepad_app LOGIN;
  END IF;
END;
$$;
ALTER ROLE keycloak_makepad_app LOGIN PASSWORD :'keycloak_makepad_app_password';
SELECT 'CREATE DATABASE keycloak_makepad OWNER keycloak_makepad_app'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'keycloak_makepad') \gexec
SELECT 'ALTER DATABASE keycloak_makepad OWNER TO keycloak_makepad_app'
WHERE EXISTS (
  SELECT 1
  FROM pg_database d
  JOIN pg_roles r ON r.oid = d.datdba
  WHERE d.datname = 'keycloak_makepad'
    AND r.rolname <> 'keycloak_makepad_app'
) \gexec
GRANT CONNECT ON DATABASE keycloak_makepad TO keycloak_makepad_app;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'keycloak_vestiaire_app') THEN
    CREATE ROLE keycloak_vestiaire_app LOGIN;
  END IF;
END;
$$;
ALTER ROLE keycloak_vestiaire_app LOGIN PASSWORD :'keycloak_vestiaire_app_password';
SELECT 'CREATE DATABASE keycloak_vestiaire OWNER keycloak_vestiaire_app'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'keycloak_vestiaire') \gexec
SELECT 'ALTER DATABASE keycloak_vestiaire OWNER TO keycloak_vestiaire_app'
WHERE EXISTS (
  SELECT 1
  FROM pg_database d
  JOIN pg_roles r ON r.oid = d.datdba
  WHERE d.datname = 'keycloak_vestiaire'
    AND r.rolname <> 'keycloak_vestiaire_app'
) \gexec
GRANT CONNECT ON DATABASE keycloak_vestiaire TO keycloak_vestiaire_app;

SELECT pg_advisory_unlock(hashtext('makepad-postgres'), hashtext('keycloak-bootstrap'));
