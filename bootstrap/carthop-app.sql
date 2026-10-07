\set ON_ERROR_STOP on
\if :{?carthop_app_password}
\else
  \echo 'missing carthop_app_password'
  DO $$ BEGIN RAISE EXCEPTION 'CartHop bootstrap precondition failed'; END $$;
\endif
SELECT length(:'carthop_app_password') >= 32 AS strong_password \gset
\if :strong_password
\else
  \echo 'carthop_app_password must contain at least 32 characters'
  DO $$ BEGIN RAISE EXCEPTION 'CartHop bootstrap precondition failed'; END $$;
\endif
SELECT pg_advisory_lock(hashtext('makepad-postgres'),hashtext('carthop-bootstrap'));
SELECT NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='carthop_app') AND NOT EXISTS(SELECT 1 FROM pg_database WHERE datname='carthop') AS fresh_install \gset
\if :fresh_install
CREATE ROLE carthop_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD :'carthop_app_password';
CREATE DATABASE carthop OWNER carthop_app;
REVOKE ALL ON DATABASE carthop FROM PUBLIC;
GRANT CONNECT ON DATABASE carthop TO carthop_app;
\else
  SELECT EXISTS(
    SELECT 1 FROM pg_database d JOIN pg_roles r ON d.datdba=r.oid
    WHERE d.datname='carthop' AND r.rolname='carthop_app'
      AND r.rolcanlogin AND NOT r.rolsuper AND NOT r.rolcreatedb
      AND NOT r.rolcreaterole AND NOT r.rolreplication AND NOT r.rolbypassrls
      AND NOT EXISTS(SELECT 1 FROM pg_auth_members m WHERE m.member=r.oid OR m.roleid=r.oid)
      AND NOT EXISTS(SELECT 1 FROM aclexplode(COALESCE(d.datacl,acldefault('d',d.datdba))) a WHERE a.grantee<>d.datdba)
  ) AS existing_is_scoped \gset
  \if :existing_is_scoped
    \echo 'Existing CartHop ownership and isolation verified; credentials unchanged.'
  \else
    DO $$ BEGIN RAISE EXCEPTION 'Existing CartHop installation is incomplete or unsafe'; END $$;
  \endif
\endif
SELECT pg_advisory_unlock(hashtext('makepad-postgres'),hashtext('carthop-bootstrap'));
