\set ON_ERROR_STOP on

-- Run with a PostgreSQL superuser connection. This idempotently provisions
-- Amiary production, canary, and identity databases without embedding secrets.
-- Application migrations own schema/object grants; this bootstrap owns only
-- cluster roles, memberships, database ownership, and database CONNECT policy.

\if :{?amiary_migrator_password}
\else
  \echo 'missing required psql variable: amiary_migrator_password'
  \quit 1
\endif
\if :{?amiary_api_prod_password}
\else
  \echo 'missing required psql variable: amiary_api_prod_password'
  \quit 1
\endif
\if :{?amiary_worker_prod_password}
\else
  \echo 'missing required psql variable: amiary_worker_prod_password'
  \quit 1
\endif
\if :{?amiary_canary_migrator_password}
\else
  \echo 'missing required psql variable: amiary_canary_migrator_password'
  \quit 1
\endif
\if :{?amiary_api_canary_password}
\else
  \echo 'missing required psql variable: amiary_api_canary_password'
  \quit 1
\endif
\if :{?amiary_worker_canary_password}
\else
  \echo 'missing required psql variable: amiary_worker_canary_password'
  \quit 1
\endif
\if :{?keycloak_amiary_app_password}
\else
  \echo 'missing required psql variable: keycloak_amiary_app_password'
  \quit 1
\endif
\if :{?makepad_backup_password}
\else
  \echo 'missing required psql variable: makepad_backup_password'
  \quit 1
\endif

SELECT CASE WHEN NULLIF(btrim(:'amiary_migrator_password'), '') IS NULL THEN 'false' ELSE 'true' END AS amiary_migrator_password_is_nonempty \gset
SELECT CASE WHEN NULLIF(btrim(:'amiary_api_prod_password'), '') IS NULL THEN 'false' ELSE 'true' END AS amiary_api_prod_password_is_nonempty \gset
SELECT CASE WHEN NULLIF(btrim(:'amiary_worker_prod_password'), '') IS NULL THEN 'false' ELSE 'true' END AS amiary_worker_prod_password_is_nonempty \gset
SELECT CASE WHEN NULLIF(btrim(:'amiary_canary_migrator_password'), '') IS NULL THEN 'false' ELSE 'true' END AS amiary_canary_migrator_password_is_nonempty \gset
SELECT CASE WHEN NULLIF(btrim(:'amiary_api_canary_password'), '') IS NULL THEN 'false' ELSE 'true' END AS amiary_api_canary_password_is_nonempty \gset
SELECT CASE WHEN NULLIF(btrim(:'amiary_worker_canary_password'), '') IS NULL THEN 'false' ELSE 'true' END AS amiary_worker_canary_password_is_nonempty \gset
SELECT CASE WHEN NULLIF(btrim(:'keycloak_amiary_app_password'), '') IS NULL THEN 'false' ELSE 'true' END AS keycloak_amiary_app_password_is_nonempty \gset
SELECT CASE WHEN NULLIF(btrim(:'makepad_backup_password'), '') IS NULL THEN 'false' ELSE 'true' END AS makepad_backup_password_is_nonempty \gset

\if :amiary_migrator_password_is_nonempty
\else
  \echo 'empty required psql variable: amiary_migrator_password'
  \quit 1
\endif
\if :amiary_api_prod_password_is_nonempty
\else
  \echo 'empty required psql variable: amiary_api_prod_password'
  \quit 1
\endif
\if :amiary_worker_prod_password_is_nonempty
\else
  \echo 'empty required psql variable: amiary_worker_prod_password'
  \quit 1
\endif
\if :amiary_canary_migrator_password_is_nonempty
\else
  \echo 'empty required psql variable: amiary_canary_migrator_password'
  \quit 1
\endif
\if :amiary_api_canary_password_is_nonempty
\else
  \echo 'empty required psql variable: amiary_api_canary_password'
  \quit 1
\endif
\if :amiary_worker_canary_password_is_nonempty
\else
  \echo 'empty required psql variable: amiary_worker_canary_password'
  \quit 1
\endif
\if :keycloak_amiary_app_password_is_nonempty
\else
  \echo 'empty required psql variable: keycloak_amiary_app_password'
  \quit 1
\endif
\if :makepad_backup_password_is_nonempty
\else
  \echo 'empty required psql variable: makepad_backup_password'
  \quit 1
\endif

SELECT pg_advisory_lock(hashtext('makepad-postgres'), hashtext('amiary-bootstrap'));

-- Shared capability roles never authenticate. Only the definer role may bypass
-- RLS, and it receives no database CONNECT privilege from this bootstrap.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'amiary_api') THEN
    CREATE ROLE amiary_api NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'amiary_worker') THEN
    CREATE ROLE amiary_worker NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'amiary_security_definer') THEN
    CREATE ROLE amiary_security_definer NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION BYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'makepad_backup') THEN
    CREATE ROLE makepad_backup LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'makepad_backup_reader') THEN
    CREATE ROLE makepad_backup_reader NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION BYPASSRLS;
  END IF;
END;
$$;
ALTER ROLE amiary_api NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
ALTER ROLE amiary_worker NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
ALTER ROLE amiary_security_definer NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION BYPASSRLS;
ALTER ROLE makepad_backup LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD :'makepad_backup_password';
ALTER ROLE makepad_backup_reader NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION BYPASSRLS;
ALTER ROLE makepad_backup SET statement_timeout = '30min';
ALTER ROLE makepad_backup SET idle_in_transaction_session_timeout = '30s';

-- Production login roles. The migrator owns the database; runtime roles only
-- inherit their matching capability role and receive direct CONNECT.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'amiary_migrator') THEN
    CREATE ROLE amiary_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'amiary_api_prod') THEN
    CREATE ROLE amiary_api_prod LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'amiary_worker_prod') THEN
    CREATE ROLE amiary_worker_prod LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION NOBYPASSRLS;
  END IF;
END;
$$;
ALTER ROLE amiary_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD :'amiary_migrator_password';
ALTER ROLE amiary_api_prod LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION NOBYPASSRLS PASSWORD :'amiary_api_prod_password';
ALTER ROLE amiary_worker_prod LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION NOBYPASSRLS PASSWORD :'amiary_worker_prod_password';

ALTER ROLE amiary_api_prod SET statement_timeout = '30s';
ALTER ROLE amiary_api_prod SET idle_in_transaction_session_timeout = '30s';
ALTER ROLE amiary_worker_prod SET statement_timeout = '5min';
ALTER ROLE amiary_worker_prod SET idle_in_transaction_session_timeout = '30s';

-- Canary login roles are distinct credentials and cannot connect to production.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'amiary_canary_migrator') THEN
    CREATE ROLE amiary_canary_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'amiary_api_canary') THEN
    CREATE ROLE amiary_api_canary LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'amiary_worker_canary') THEN
    CREATE ROLE amiary_worker_canary LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION NOBYPASSRLS;
  END IF;
END;
$$;
ALTER ROLE amiary_canary_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD :'amiary_canary_migrator_password';
ALTER ROLE amiary_api_canary LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION NOBYPASSRLS PASSWORD :'amiary_api_canary_password';
ALTER ROLE amiary_worker_canary LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION NOBYPASSRLS PASSWORD :'amiary_worker_canary_password';

ALTER ROLE amiary_api_canary SET statement_timeout = '30s';
ALTER ROLE amiary_api_canary SET idle_in_transaction_session_timeout = '30s';
ALTER ROLE amiary_worker_canary SET statement_timeout = '5min';
ALTER ROLE amiary_worker_canary SET idle_in_transaction_session_timeout = '30s';

-- Membership options are explicit: runtime privileges are inherited without
-- SET ROLE; only migrators may deliberately SET ROLE to the definer owner.
WITH desired(granted_role, member_role, inherit_membership, set_membership) AS (
  VALUES
    ('amiary_api', 'amiary_api_prod', true, false),
    ('amiary_api', 'amiary_api_canary', true, false),
    ('amiary_worker', 'amiary_worker_prod', true, false),
    ('amiary_worker', 'amiary_worker_canary', true, false),
    ('amiary_security_definer', 'amiary_migrator', false, true),
    ('amiary_security_definer', 'amiary_canary_migrator', false, true),
    ('pg_read_all_data', 'makepad_backup_reader', true, false),
    ('makepad_backup_reader', 'makepad_backup', false, true)
)
SELECT format(
  'GRANT %I TO %I WITH ADMIN FALSE, INHERIT %s, SET %s',
  desired.granted_role,
  desired.member_role,
  upper(desired.inherit_membership::text),
  upper(desired.set_membership::text)
)
FROM desired
WHERE NOT EXISTS (
  SELECT 1
  FROM pg_auth_members membership
  JOIN pg_roles granted ON granted.oid = membership.roleid
  JOIN pg_roles member ON member.oid = membership.member
  WHERE granted.rolname = desired.granted_role
    AND member.rolname = desired.member_role
    AND NOT membership.admin_option
    AND membership.inherit_option = desired.inherit_membership
    AND membership.set_option = desired.set_membership
) \gexec

-- Remove every undeclared membership held by an Amiary login. This repairs
-- pre-existing cross-application role drift, not only drift involving the
-- three Amiary capability roles. Conditional generation keeps reruns quiet.
WITH allowed(granted_role, member_role) AS (
  VALUES
    ('amiary_api', 'amiary_api_prod'),
    ('amiary_api', 'amiary_api_canary'),
    ('amiary_worker', 'amiary_worker_prod'),
    ('amiary_worker', 'amiary_worker_canary'),
    ('amiary_security_definer', 'amiary_migrator'),
    ('amiary_security_definer', 'amiary_canary_migrator'),
    ('pg_read_all_data', 'makepad_backup_reader'),
    ('makepad_backup_reader', 'makepad_backup')
)
SELECT format('REVOKE %I FROM %I', granted.rolname, member.rolname)
FROM pg_auth_members membership
JOIN pg_roles granted ON granted.oid = membership.roleid
JOIN pg_roles member ON member.oid = membership.member
WHERE member.rolname IN (
    'amiary_migrator',
    'amiary_api_prod',
    'amiary_worker_prod',
    'amiary_canary_migrator',
    'amiary_api_canary',
    'amiary_worker_canary',
    'keycloak_amiary_app',
    'makepad_backup',
    'makepad_backup_reader'
  )
  AND NOT EXISTS (
    SELECT 1
    FROM allowed
    WHERE allowed.granted_role = granted.rolname
      AND allowed.member_role = member.rolname
  )
ORDER BY granted.rolname, member.rolname
\gexec

SELECT 'CREATE DATABASE amiary OWNER amiary_migrator'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'amiary') \gexec
SELECT 'ALTER DATABASE amiary OWNER TO amiary_migrator'
WHERE EXISTS (
  SELECT 1 FROM pg_database d JOIN pg_roles r ON r.oid = d.datdba
  WHERE d.datname = 'amiary' AND r.rolname <> 'amiary_migrator'
) \gexec
REVOKE ALL PRIVILEGES ON DATABASE amiary FROM PUBLIC;
REVOKE ALL PRIVILEGES ON DATABASE amiary FROM amiary_api, amiary_worker, amiary_security_definer, amiary_api_prod, amiary_worker_prod, amiary_canary_migrator, amiary_api_canary, amiary_worker_canary;
GRANT CONNECT ON DATABASE amiary TO amiary_migrator, amiary_api_prod, amiary_worker_prod;
ALTER DATABASE amiary SET timezone TO 'UTC';

SELECT 'CREATE DATABASE amiary_canary OWNER amiary_canary_migrator'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'amiary_canary') \gexec
SELECT 'ALTER DATABASE amiary_canary OWNER TO amiary_canary_migrator'
WHERE EXISTS (
  SELECT 1 FROM pg_database d JOIN pg_roles r ON r.oid = d.datdba
  WHERE d.datname = 'amiary_canary' AND r.rolname <> 'amiary_canary_migrator'
) \gexec
REVOKE ALL PRIVILEGES ON DATABASE amiary_canary FROM PUBLIC;
REVOKE ALL PRIVILEGES ON DATABASE amiary_canary FROM amiary_api, amiary_worker, amiary_security_definer, amiary_migrator, amiary_api_prod, amiary_worker_prod, amiary_api_canary, amiary_worker_canary;
GRANT CONNECT ON DATABASE amiary_canary TO amiary_canary_migrator, amiary_api_canary, amiary_worker_canary;
ALTER DATABASE amiary_canary SET timezone TO 'UTC';

-- Preserve the dedicated Keycloak role/database pair.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'keycloak_amiary_app') THEN
    CREATE ROLE keycloak_amiary_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
  END IF;
END;
$$;
ALTER ROLE keycloak_amiary_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD :'keycloak_amiary_app_password';
REVOKE ALL PRIVILEGES ON DATABASE amiary FROM keycloak_amiary_app;
REVOKE ALL PRIVILEGES ON DATABASE amiary_canary FROM keycloak_amiary_app;
SELECT 'CREATE DATABASE keycloak_amiary OWNER keycloak_amiary_app'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'keycloak_amiary') \gexec
SELECT 'ALTER DATABASE keycloak_amiary OWNER TO keycloak_amiary_app'
WHERE EXISTS (
  SELECT 1 FROM pg_database d JOIN pg_roles r ON r.oid = d.datdba
  WHERE d.datname = 'keycloak_amiary' AND r.rolname <> 'keycloak_amiary_app'
) \gexec
REVOKE ALL PRIVILEGES ON DATABASE keycloak_amiary FROM PUBLIC;
REVOKE ALL PRIVILEGES ON DATABASE keycloak_amiary FROM amiary_api, amiary_worker, amiary_security_definer, amiary_migrator, amiary_api_prod, amiary_worker_prod, amiary_canary_migrator, amiary_api_canary, amiary_worker_canary;
GRANT CONNECT ON DATABASE keycloak_amiary TO keycloak_amiary_app;
ALTER DATABASE keycloak_amiary SET timezone TO 'UTC';

-- The scheduled backup login never receives superuser or write privileges. It
-- connects only to the five protected databases and pg_dump explicitly uses
-- SET ROLE makepad_backup_reader. That NOLOGIN role has read-only data access
-- and BYPASSRLS (required for a complete forced-RLS backup); the login is
-- NOINHERIT and has neither capability at all other times.
SELECT format('REVOKE ALL PRIVILEGES ON DATABASE %I FROM makepad_backup', database.datname)
FROM pg_database database
WHERE database.datname IN ('runtrace', 'keycloak_runtrace', 'amiary', 'amiary_canary', 'keycloak_amiary')
ORDER BY database.datname
\gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO makepad_backup', database.datname)
FROM pg_database database
WHERE database.datname IN ('runtrace', 'keycloak_runtrace', 'amiary', 'amiary_canary', 'keycloak_amiary')
ORDER BY database.datname
\gexec

SELECT pg_advisory_unlock(hashtext('makepad-postgres'), hashtext('amiary-bootstrap'));
