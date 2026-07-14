\set ON_ERROR_STOP on

-- Run this bootstrap with a PostgreSQL superuser connection. It creates the
-- OpenPanel application role/database pair without embedding secrets.

\if :{?openpanel_app_password}
\else
  \echo 'missing required psql variable: openpanel_app_password'
  \quit 1
\endif

SELECT CASE WHEN NULLIF(btrim(:'openpanel_app_password'), '') IS NULL THEN 'false' ELSE 'true' END AS openpanel_app_password_is_nonempty \gset
\if :openpanel_app_password_is_nonempty
\else
  \echo 'empty required psql variable: openpanel_app_password'
  \quit 1
\endif

SELECT pg_advisory_lock(hashtext('makepad-postgres'), hashtext('openpanel-app-bootstrap'));

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'openpanel_app') THEN
    CREATE ROLE openpanel_app LOGIN;
  END IF;
END;
$$;
ALTER ROLE openpanel_app LOGIN PASSWORD :'openpanel_app_password';
SELECT 'CREATE DATABASE openpanel OWNER openpanel_app'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'openpanel') \gexec
SELECT 'ALTER DATABASE openpanel OWNER TO openpanel_app'
WHERE EXISTS (
  SELECT 1
  FROM pg_database d
  JOIN pg_roles r ON r.oid = d.datdba
  WHERE d.datname = 'openpanel'
    AND r.rolname <> 'openpanel_app'
) \gexec
GRANT CONNECT ON DATABASE openpanel TO openpanel_app;

SELECT pg_advisory_unlock(hashtext('makepad-postgres'), hashtext('openpanel-app-bootstrap'));

