\set ON_ERROR_STOP on
SELECT pg_advisory_lock(hashtext('makepad-postgres'),hashtext('fashion-catalog-reader'));
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_database d JOIN pg_roles r ON d.datdba=r.oid WHERE d.datname='scraping' AND r.rolname='scraping_crawler') THEN
  RAISE EXCEPTION 'Scoped Scraping database must exist before the reader';
 END IF;
 IF EXISTS(SELECT 1 FROM pg_roles r WHERE r.rolname='fashion_catalog_reader' AND
   (NOT r.rolcanlogin OR r.rolsuper OR r.rolcreatedb OR r.rolcreaterole OR r.rolreplication OR r.rolbypassrls
    OR EXISTS(SELECT 1 FROM pg_auth_members m WHERE m.member=r.oid OR m.roleid=r.oid))) THEN
  RAISE EXCEPTION 'Existing reader privileges require review';
 END IF;
END $$;
SELECT NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='fashion_catalog_reader') AS fresh_reader \gset
\if :fresh_reader
\if :{?fashion_catalog_reader_password}
\else
 DO $$ BEGIN RAISE EXCEPTION 'Reader password required'; END $$;
\endif
SELECT length(:'fashion_catalog_reader_password')>=32 AS strong_password \gset
\if :strong_password
\else
 DO $$ BEGIN RAISE EXCEPTION 'Reader password must contain 32 characters'; END $$;
\endif
CREATE ROLE fashion_catalog_reader LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'fashion_catalog_reader_password';
\endif
GRANT CONNECT ON DATABASE scraping TO fashion_catalog_reader;
SELECT pg_advisory_unlock(hashtext('makepad-postgres'),hashtext('fashion-catalog-reader'));
\connect scraping
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p')
   AND has_table_privilege('fashion_catalog_reader',c.oid,'INSERT,UPDATE,DELETE,TRUNCATE,TRIGGER')) THEN
  RAISE EXCEPTION 'Existing catalog reader can mutate tables';
 END IF;
END $$;
GRANT USAGE ON SCHEMA public TO fashion_catalog_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO fashion_catalog_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE scraping_crawler IN SCHEMA public GRANT SELECT ON TABLES TO fashion_catalog_reader;
