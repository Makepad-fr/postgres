\set ON_ERROR_STOP on

-- Run this bootstrap with a PostgreSQL superuser connection. It creates the
-- Fashion crawler application role/database pair without embedding secrets.

\if :{?fashion_crawler_password}
\else
  \echo 'missing required psql variable: fashion_crawler_password'
  \quit 1
\endif

SELECT CASE WHEN NULLIF(btrim(:'fashion_crawler_password'), '') IS NULL THEN 'false' ELSE 'true' END AS fashion_crawler_password_is_nonempty \gset
\if :fashion_crawler_password_is_nonempty
\else
  \echo 'empty required psql variable: fashion_crawler_password'
  \quit 1
\endif

SELECT pg_advisory_lock(hashtext('makepad-postgres'), hashtext('fashion-app-bootstrap'));

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'fashion_crawler') THEN
    CREATE ROLE fashion_crawler LOGIN;
  END IF;
END;
$$;
ALTER ROLE fashion_crawler LOGIN PASSWORD :'fashion_crawler_password';
SELECT 'CREATE DATABASE fashion OWNER fashion_crawler'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'fashion') \gexec
SELECT 'ALTER DATABASE fashion OWNER TO fashion_crawler'
WHERE EXISTS (
  SELECT 1
  FROM pg_database d
  JOIN pg_roles r ON r.oid = d.datdba
  WHERE d.datname = 'fashion'
    AND r.rolname <> 'fashion_crawler'
) \gexec
GRANT CONNECT ON DATABASE fashion TO fashion_crawler;

SELECT pg_advisory_unlock(hashtext('makepad-postgres'), hashtext('fashion-app-bootstrap'));
