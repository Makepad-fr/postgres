\set ON_ERROR_STOP on

-- Targeted first deployment for Runtrace identity data. Use a PostgreSQL
-- superuser connection; the consolidated bootstrap remains available when
-- provisioning every Keycloak instance together.

\if :{?keycloak_runtrace_app_password}
\else
  \echo 'missing required psql variable: keycloak_runtrace_app_password'
  \quit 1
\endif

SELECT CASE WHEN NULLIF(btrim(:'keycloak_runtrace_app_password'), '') IS NULL THEN 'false' ELSE 'true' END AS keycloak_runtrace_app_password_is_nonempty \gset
\if :keycloak_runtrace_app_password_is_nonempty
\else
  \echo 'empty required psql variable: keycloak_runtrace_app_password'
  \quit 1
\endif

SELECT pg_advisory_lock(hashtext('makepad-postgres'), hashtext('keycloak-runtrace-bootstrap'));

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'keycloak_runtrace_app') THEN
    CREATE ROLE keycloak_runtrace_app LOGIN;
  END IF;
END;
$$;
ALTER ROLE keycloak_runtrace_app LOGIN PASSWORD :'keycloak_runtrace_app_password';
SELECT 'CREATE DATABASE keycloak_runtrace OWNER keycloak_runtrace_app'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'keycloak_runtrace') \gexec
SELECT 'ALTER DATABASE keycloak_runtrace OWNER TO keycloak_runtrace_app'
WHERE EXISTS (
  SELECT 1
  FROM pg_database d
  JOIN pg_roles r ON r.oid = d.datdba
  WHERE d.datname = 'keycloak_runtrace'
    AND r.rolname <> 'keycloak_runtrace_app'
) \gexec
GRANT CONNECT ON DATABASE keycloak_runtrace TO keycloak_runtrace_app;

SELECT pg_advisory_unlock(hashtext('makepad-postgres'), hashtext('keycloak-runtrace-bootstrap'));
