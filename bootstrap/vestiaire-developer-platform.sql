\set ON_ERROR_STOP on
SELECT pg_advisory_lock(hashtext('makepad-postgres'),hashtext('vestiaire_developer-bootstrap'));
SELECT NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='vestiaire_developer_app') AND NOT EXISTS(SELECT 1 FROM pg_database WHERE datname='vestiaire_developer') AS fresh_install \gset
\if :fresh_install
\if :{?vestiaire_developer_app_password}
\else
  \echo 'missing vestiaire_developer_app_password'
  DO $$ BEGIN RAISE EXCEPTION 'Vestiaire bootstrap precondition failed'; END $$;
\endif
SELECT length(:'vestiaire_developer_app_password') >= 32 AS strong_password \gset
\if :strong_password
\else
  \echo 'vestiaire_developer_app_password must contain at least 32 characters'
  DO $$ BEGIN RAISE EXCEPTION 'Vestiaire bootstrap precondition failed'; END $$;
\endif
CREATE ROLE vestiaire_developer_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'vestiaire_developer_app_password';
CREATE DATABASE vestiaire_developer OWNER vestiaire_developer_app;
REVOKE ALL ON DATABASE vestiaire_developer FROM PUBLIC;
GRANT CONNECT ON DATABASE vestiaire_developer TO vestiaire_developer_app;
\else
  SELECT EXISTS(
    SELECT 1 FROM pg_database d JOIN pg_roles r ON d.datdba=r.oid
    WHERE d.datname='vestiaire_developer' AND r.rolname='vestiaire_developer_app'
      AND r.rolcanlogin AND NOT r.rolsuper AND NOT r.rolcreatedb
      AND NOT r.rolcreaterole AND NOT r.rolreplication AND NOT r.rolbypassrls
      AND NOT EXISTS(SELECT 1 FROM pg_auth_members m WHERE m.member=r.oid OR m.roleid=r.oid)
      AND NOT EXISTS(SELECT 1 FROM aclexplode(COALESCE(d.datacl,acldefault('d',d.datdba))) a WHERE a.grantee<>d.datdba)
  ) AS existing_is_scoped \gset
  \if :existing_is_scoped
    \echo 'Existing Vestiaire ownership and isolation verified; credentials unchanged.'
  \else
    DO $$ BEGIN RAISE EXCEPTION 'Existing Vestiaire installation is incomplete or unsafe'; END $$;
  \endif
\endif
SELECT pg_advisory_unlock(hashtext('makepad-postgres'),hashtext('vestiaire_developer-bootstrap'));
