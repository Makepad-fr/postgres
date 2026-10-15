\set ON_ERROR_STOP on

-- Run with a PostgreSQL superuser connection. Passwords are supplied as psql
-- variables so credentials never enter source control.
\if :{?betacrew_app_password}
\else
  \echo 'missing required psql variable: betacrew_app_password'
  SELECT 1/0;
\endif
\if :{?keycloak_betacrew_app_password}
\else
  \echo 'missing required psql variable: keycloak_betacrew_app_password'
  SELECT 1/0;
\endif

SELECT length(:'betacrew_app_password') >= 32 AS betacrew_password_ok \gset
\if :betacrew_password_ok
\else
  \echo 'empty required psql variable: betacrew_app_password'
  SELECT 1/0;
\endif
SELECT length(:'keycloak_betacrew_app_password') >= 32 AS keycloak_betacrew_password_ok \gset
\if :keycloak_betacrew_password_ok
\else
  \echo 'empty required psql variable: keycloak_betacrew_app_password'
  SELECT 1/0;
\endif

SELECT pg_advisory_lock(hashtext('makepad-postgres'), hashtext('betacrew-databases-bootstrap'));

-- Validate both pairs before changing either. Existing objects must already be
-- isolated; never seize ownership or rotate a live credential during bootstrap.
DO $$
DECLARE target record; role_row pg_roles%ROWTYPE; database_row pg_database%ROWTYPE;
BEGIN
  FOR target IN SELECT * FROM (VALUES
    ('betacrew','betacrew_app'),('keycloak_betacrew','keycloak_betacrew_app')
  ) AS targets(database_name,role_name) LOOP
    SELECT * INTO role_row FROM pg_roles WHERE rolname=target.role_name;
    SELECT * INTO database_row FROM pg_database WHERE datname=target.database_name;
    IF (role_row.oid IS NULL) <> (database_row.oid IS NULL) THEN
      RAISE EXCEPTION 'Incomplete existing BetaCrew role/database pair';
    END IF;
    IF role_row.oid IS NOT NULL THEN
      IF NOT role_row.rolcanlogin OR role_row.rolsuper OR role_row.rolcreatedb
         OR role_row.rolcreaterole OR role_row.rolreplication OR role_row.rolbypassrls
         OR EXISTS(SELECT 1 FROM pg_auth_members WHERE member=role_row.oid OR roleid=role_row.oid)
         OR database_row.datdba<>role_row.oid
         OR EXISTS(SELECT 1 FROM aclexplode(COALESCE(database_row.datacl,acldefault('d',database_row.datdba))) WHERE grantee<>role_row.oid)
      THEN RAISE EXCEPTION 'Existing BetaCrew privileges, membership, ownership or ACL require manual inspection';
      END IF;
    END IF;
  END LOOP;
END $$;

SELECT format('CREATE ROLE betacrew_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD %L', :'betacrew_app_password')
WHERE NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='betacrew_app') \gexec
SELECT 'CREATE DATABASE betacrew OWNER betacrew_app'
WHERE NOT EXISTS(SELECT 1 FROM pg_database WHERE datname='betacrew') \gexec
REVOKE ALL ON DATABASE betacrew FROM PUBLIC;
SELECT format('CREATE ROLE keycloak_betacrew_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD %L', :'keycloak_betacrew_app_password')
WHERE NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='keycloak_betacrew_app') \gexec
SELECT 'CREATE DATABASE keycloak_betacrew OWNER keycloak_betacrew_app'
WHERE NOT EXISTS(SELECT 1 FROM pg_database WHERE datname='keycloak_betacrew') \gexec
REVOKE ALL ON DATABASE keycloak_betacrew FROM PUBLIC;

SELECT pg_advisory_unlock(hashtext('makepad-postgres'), hashtext('betacrew-databases-bootstrap'));
