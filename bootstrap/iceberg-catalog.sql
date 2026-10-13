\set ON_ERROR_STOP on
SELECT pg_advisory_lock(hashtext('makepad-postgres'),hashtext('iceberg_catalog-bootstrap'));
SELECT NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='iceberg_catalog') AND NOT EXISTS(SELECT 1 FROM pg_database WHERE datname='iceberg_catalog') AS fresh_install \gset
\if :fresh_install
\if :{?iceberg_catalog_password}
\else
  \echo 'missing iceberg_catalog_password'
  DO $$ BEGIN RAISE EXCEPTION 'Iceberg bootstrap precondition failed'; END $$;
\endif
SELECT length(:'iceberg_catalog_password') >= 32 AS strong_password \gset
\if :strong_password
\else
  \echo 'iceberg_catalog_password must contain at least 32 characters'
  DO $$ BEGIN RAISE EXCEPTION 'Iceberg bootstrap precondition failed'; END $$;
\endif
CREATE ROLE iceberg_catalog LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'iceberg_catalog_password';
CREATE DATABASE iceberg_catalog OWNER iceberg_catalog;
REVOKE ALL ON DATABASE iceberg_catalog FROM PUBLIC;
GRANT CONNECT ON DATABASE iceberg_catalog TO iceberg_catalog;
\else
  SELECT EXISTS(
    SELECT 1 FROM pg_database d JOIN pg_roles r ON d.datdba=r.oid
    WHERE d.datname='iceberg_catalog' AND r.rolname='iceberg_catalog'
      AND r.rolcanlogin AND NOT r.rolsuper AND NOT r.rolcreatedb
      AND NOT r.rolcreaterole AND NOT r.rolreplication AND NOT r.rolbypassrls
      AND NOT EXISTS(SELECT 1 FROM pg_auth_members m WHERE m.member=r.oid OR m.roleid=r.oid)
      AND NOT EXISTS(SELECT 1 FROM aclexplode(COALESCE(d.datacl,acldefault('d',d.datdba))) a WHERE a.grantee<>d.datdba)
  ) AS existing_is_scoped \gset
  \if :existing_is_scoped
    \echo 'Existing Iceberg ownership and isolation verified; credentials unchanged.'
  \else
    DO $$ BEGIN RAISE EXCEPTION 'Existing Iceberg installation is incomplete or unsafe'; END $$;
  \endif
\endif
SELECT pg_advisory_unlock(hashtext('makepad-postgres'),hashtext('iceberg_catalog-bootstrap'));
