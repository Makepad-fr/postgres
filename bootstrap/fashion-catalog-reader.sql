\set ON_ERROR_STOP on

-- Provision the catalog inventory reader without changing crawler credentials.
\if :{?fashion_catalog_reader_password}
\else
  \echo 'missing required psql variable: fashion_catalog_reader_password'
  \quit 1
\endif

SELECT CASE
  WHEN NULLIF(btrim(:'fashion_catalog_reader_password'), '') IS NULL THEN 'false'
  ELSE 'true'
END AS fashion_catalog_reader_password_is_nonempty \gset
\if :fashion_catalog_reader_password_is_nonempty
\else
  \echo 'empty required psql variable: fashion_catalog_reader_password'
  \quit 1
\endif

SELECT pg_advisory_lock(hashtext('makepad-postgres'), hashtext('fashion-catalog-reader'));

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'fashion_catalog_reader') THEN
    CREATE ROLE fashion_catalog_reader LOGIN;
  END IF;
END;
$$;
ALTER ROLE fashion_catalog_reader LOGIN PASSWORD :'fashion_catalog_reader_password';
GRANT CONNECT ON DATABASE scraping TO fashion_catalog_reader;

SELECT pg_advisory_unlock(hashtext('makepad-postgres'), hashtext('fashion-catalog-reader'));

\connect scraping

GRANT USAGE ON SCHEMA public TO fashion_catalog_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO fashion_catalog_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE scraping_crawler IN SCHEMA public
  GRANT SELECT ON TABLES TO fashion_catalog_reader;
