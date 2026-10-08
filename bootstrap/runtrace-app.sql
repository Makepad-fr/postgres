\set ON_ERROR_STOP on

-- Run this bootstrap with a PostgreSQL superuser connection. It creates the
-- Runtrace application role/database pair without embedding secrets.

\if :{?runtrace_app_password}
\else
  \echo 'missing required psql variable: runtrace_app_password'
  \quit 1
\endif

SELECT CASE WHEN NULLIF(btrim(:'runtrace_app_password'), '') IS NULL THEN 'false' ELSE 'true' END AS runtrace_app_password_is_nonempty \gset
\if :runtrace_app_password_is_nonempty
\else
  \echo 'empty required psql variable: runtrace_app_password'
  \quit 1
\endif

SELECT pg_advisory_lock(hashtext('makepad-postgres'), hashtext('runtrace-app-bootstrap'));

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'runtrace_app') THEN
    CREATE ROLE runtrace_app LOGIN;
  END IF;
END;
$$;
ALTER ROLE runtrace_app LOGIN PASSWORD :'runtrace_app_password';
SELECT 'CREATE DATABASE runtrace OWNER runtrace_app'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'runtrace') \gexec
SELECT 'ALTER DATABASE runtrace OWNER TO runtrace_app'
WHERE EXISTS (
  SELECT 1
  FROM pg_database d
  JOIN pg_roles r ON r.oid = d.datdba
  WHERE d.datname = 'runtrace'
    AND r.rolname <> 'runtrace_app'
) \gexec
GRANT CONNECT ON DATABASE runtrace TO runtrace_app;

SELECT pg_advisory_unlock(hashtext('makepad-postgres'), hashtext('runtrace-app-bootstrap'));
