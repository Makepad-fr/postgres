\set ON_ERROR_STOP on

-- Run this bootstrap with a PostgreSQL superuser connection. It creates the
-- Scraping crawler application role/database pair without embedding secrets.

\if :{?scraping_crawler_password}
\else
  \echo 'missing required psql variable: scraping_crawler_password'
  \quit 1
\endif

\if :{?fashion_catalog_reader_password}
\else
  \echo 'missing required psql variable: fashion_catalog_reader_password'
  \quit 1
\endif

SELECT CASE WHEN NULLIF(btrim(:'scraping_crawler_password'), '') IS NULL THEN 'false' ELSE 'true' END AS scraping_crawler_password_is_nonempty \gset
\if :scraping_crawler_password_is_nonempty
\else
  \echo 'empty required psql variable: scraping_crawler_password'
  \quit 1
\endif

SELECT CASE WHEN NULLIF(btrim(:'fashion_catalog_reader_password'), '') IS NULL THEN 'false' ELSE 'true' END AS fashion_catalog_reader_password_is_nonempty \gset
\if :fashion_catalog_reader_password_is_nonempty
\else
  \echo 'empty required psql variable: fashion_catalog_reader_password'
  \quit 1
\endif

SELECT pg_advisory_lock(hashtext('makepad-postgres'), hashtext('scraping-app-bootstrap'));

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'scraping_crawler') THEN
    CREATE ROLE scraping_crawler LOGIN;
  END IF;
END;
$$;
ALTER ROLE scraping_crawler LOGIN PASSWORD :'scraping_crawler_password';
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'fashion_catalog_reader') THEN
    CREATE ROLE fashion_catalog_reader LOGIN;
  END IF;
END;
$$;
ALTER ROLE fashion_catalog_reader LOGIN PASSWORD :'fashion_catalog_reader_password';
SELECT 'CREATE DATABASE scraping OWNER scraping_crawler'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'scraping') \gexec
SELECT 'ALTER DATABASE scraping OWNER TO scraping_crawler'
WHERE EXISTS (
  SELECT 1
  FROM pg_database d
  JOIN pg_roles r ON r.oid = d.datdba
  WHERE d.datname = 'scraping'
    AND r.rolname <> 'scraping_crawler'
) \gexec
GRANT CONNECT ON DATABASE scraping TO scraping_crawler;
GRANT CONNECT ON DATABASE scraping TO fashion_catalog_reader;

SELECT pg_advisory_unlock(hashtext('makepad-postgres'), hashtext('scraping-app-bootstrap'));

\connect scraping

GRANT USAGE ON SCHEMA public TO fashion_catalog_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO fashion_catalog_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE scraping_crawler IN SCHEMA public
  GRANT SELECT ON TABLES TO fashion_catalog_reader;
