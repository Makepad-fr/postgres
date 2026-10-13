\set ON_ERROR_STOP on
SELECT pg_advisory_lock(hashtext('makepad-postgres'),hashtext('scraping-bootstrap'));
SELECT NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='scraping_crawler') AND NOT EXISTS(SELECT 1 FROM pg_database WHERE datname='scraping') AS fresh_install \gset
\if :fresh_install
\if :{?scraping_crawler_password}
\else
  \echo 'missing scraping_crawler_password'
  DO $$ BEGIN RAISE EXCEPTION 'Scraping bootstrap precondition failed'; END $$;
\endif
SELECT length(:'scraping_crawler_password') >= 32 AS strong_password \gset
\if :strong_password
\else
  \echo 'scraping_crawler_password must contain at least 32 characters'
  DO $$ BEGIN RAISE EXCEPTION 'Scraping bootstrap precondition failed'; END $$;
\endif
CREATE ROLE scraping_crawler LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'scraping_crawler_password';
CREATE DATABASE scraping OWNER scraping_crawler;
REVOKE ALL ON DATABASE scraping FROM PUBLIC;
GRANT CONNECT ON DATABASE scraping TO scraping_crawler;
\else
  SELECT EXISTS(
    SELECT 1 FROM pg_database d JOIN pg_roles r ON d.datdba=r.oid
    WHERE d.datname='scraping' AND r.rolname='scraping_crawler'
      AND r.rolcanlogin AND NOT r.rolsuper AND NOT r.rolcreatedb
      AND NOT r.rolcreaterole AND NOT r.rolreplication AND NOT r.rolbypassrls
      AND NOT EXISTS(SELECT 1 FROM pg_auth_members m WHERE m.member=r.oid OR m.roleid=r.oid)
      AND NOT EXISTS(SELECT 1 FROM aclexplode(COALESCE(d.datacl,acldefault('d',d.datdba))) a WHERE a.grantee<>d.datdba AND a.grantee<>COALESCE((SELECT oid FROM pg_roles WHERE rolname='fashion_catalog_reader'),0))
  ) AS existing_is_scoped \gset
  \if :existing_is_scoped
    \echo 'Existing Scraping ownership and isolation verified; credentials unchanged.'
  \else
    DO $$ BEGIN RAISE EXCEPTION 'Existing Scraping installation is incomplete or unsafe'; END $$;
  \endif
\endif
SELECT pg_advisory_unlock(hashtext('makepad-postgres'),hashtext('scraping-bootstrap'));
