\set ON_ERROR_STOP on

-- Run with a PostgreSQL superuser connection. The role stores only Iceberg
-- catalog metadata; product data remains in object storage.

\if :{?iceberg_catalog_password}
\else
  \echo 'missing required psql variable: iceberg_catalog_password'
  \quit 1
\endif

SELECT CASE WHEN NULLIF(btrim(:'iceberg_catalog_password'), '') IS NULL THEN 'false' ELSE 'true' END AS iceberg_catalog_password_is_nonempty \gset
\if :iceberg_catalog_password_is_nonempty
\else
  \echo 'empty required psql variable: iceberg_catalog_password'
  \quit 1
\endif

SELECT pg_advisory_lock(hashtext('makepad-postgres'), hashtext('iceberg-catalog-bootstrap'));

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'iceberg_catalog') THEN
    CREATE ROLE iceberg_catalog LOGIN;
  END IF;
END;
$$;
ALTER ROLE iceberg_catalog LOGIN PASSWORD :'iceberg_catalog_password';
SELECT 'CREATE DATABASE iceberg_catalog OWNER iceberg_catalog'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'iceberg_catalog') \gexec
SELECT 'ALTER DATABASE iceberg_catalog OWNER TO iceberg_catalog'
WHERE EXISTS (
  SELECT 1
  FROM pg_database d
  JOIN pg_roles r ON r.oid = d.datdba
  WHERE d.datname = 'iceberg_catalog'
    AND r.rolname <> 'iceberg_catalog'
) \gexec
GRANT CONNECT ON DATABASE iceberg_catalog TO iceberg_catalog;

SELECT pg_advisory_unlock(hashtext('makepad-postgres'), hashtext('iceberg-catalog-bootstrap'));
