\set ON_ERROR_STOP on

-- Run with a PostgreSQL superuser connection. Passwords are supplied as psql
-- variables so credentials never enter source control.
\if :{?betacrew_app_password}
\else
  \echo 'missing required psql variable: betacrew_app_password'
  \quit 1
\endif
\if :{?keycloak_betacrew_app_password}
\else
  \echo 'missing required psql variable: keycloak_betacrew_app_password'
  \quit 1
\endif

SELECT NULLIF(btrim(:'betacrew_app_password'), '') IS NOT NULL AS betacrew_password_ok \gset
\if :betacrew_password_ok
\else
  \echo 'empty required psql variable: betacrew_app_password'
  \quit 1
\endif
SELECT NULLIF(btrim(:'keycloak_betacrew_app_password'), '') IS NOT NULL AS keycloak_betacrew_password_ok \gset
\if :keycloak_betacrew_password_ok
\else
  \echo 'empty required psql variable: keycloak_betacrew_app_password'
  \quit 1
\endif

SELECT pg_advisory_lock(hashtext('makepad-postgres'), hashtext('betacrew-databases-bootstrap'));

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'betacrew_app') THEN
    CREATE ROLE betacrew_app LOGIN;
  END IF;
END $$;
ALTER ROLE betacrew_app LOGIN PASSWORD :'betacrew_app_password';
SELECT 'CREATE DATABASE betacrew OWNER betacrew_app'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'betacrew') \gexec
ALTER DATABASE betacrew OWNER TO betacrew_app;
GRANT CONNECT ON DATABASE betacrew TO betacrew_app;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'keycloak_betacrew_app') THEN
    CREATE ROLE keycloak_betacrew_app LOGIN;
  END IF;
END $$;
ALTER ROLE keycloak_betacrew_app LOGIN PASSWORD :'keycloak_betacrew_app_password';
SELECT 'CREATE DATABASE keycloak_betacrew OWNER keycloak_betacrew_app'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'keycloak_betacrew') \gexec
ALTER DATABASE keycloak_betacrew OWNER TO keycloak_betacrew_app;
GRANT CONNECT ON DATABASE keycloak_betacrew TO keycloak_betacrew_app;

SELECT pg_advisory_unlock(hashtext('makepad-postgres'), hashtext('betacrew-databases-bootstrap'));
