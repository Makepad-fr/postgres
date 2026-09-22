\set ON_ERROR_STOP on
\if :{?visitaki_app_password}
\else
  \echo 'visitaki_app_password required'
  \quit 1
\endif
\if :{?keycloak_visitaki_app_password}
\else
  \echo 'keycloak_visitaki_app_password required'
  \quit 1
\endif
SELECT length(:'visitaki_app_password')>=32 AND length(:'keycloak_visitaki_app_password')>=32 AS secrets_valid \gset
\if :secrets_valid
\else
  \echo 'Scoped generated passwords of at least 32 characters required'
  \quit 1
\endif
SELECT pg_advisory_lock(hashtext('makepad-postgres'),hashtext('visitaki-bootstrap'));
-- Existing role credentials are never rotated by bootstrap.
SELECT format('CREATE ROLE visitaki_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION CONNECTION LIMIT 15 PASSWORD %L', :'visitaki_app_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='visitaki_app') \gexec
SELECT format('CREATE ROLE keycloak_visitaki_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION CONNECTION LIMIT 20 PASSWORD %L', :'keycloak_visitaki_app_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='keycloak_visitaki_app') \gexec
SELECT 'CREATE DATABASE visitaki OWNER visitaki_app' WHERE NOT EXISTS(SELECT 1 FROM pg_database WHERE datname='visitaki') \gexec
SELECT 'CREATE DATABASE keycloak_visitaki OWNER keycloak_visitaki_app' WHERE NOT EXISTS(SELECT 1 FROM pg_database WHERE datname='keycloak_visitaki') \gexec
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM pg_database d JOIN pg_roles r ON r.oid=d.datdba WHERE (d.datname='visitaki' AND r.rolname<>'visitaki_app') OR (d.datname='keycloak_visitaki' AND r.rolname<>'keycloak_visitaki_app')) THEN
  RAISE EXCEPTION 'Visitaki database ownership mismatch; review before changing grants';
 END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname IN ('visitaki_app','keycloak_visitaki_app') AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication)) THEN
  RAISE EXCEPTION 'Visitaki role has unexpected privileges';
 END IF;
END $$;
REVOKE ALL ON DATABASE visitaki FROM PUBLIC;
REVOKE ALL ON DATABASE keycloak_visitaki FROM PUBLIC;
GRANT CONNECT ON DATABASE visitaki TO visitaki_app;
GRANT CONNECT ON DATABASE keycloak_visitaki TO keycloak_visitaki_app;
ALTER ROLE visitaki_app SET statement_timeout='15s';
ALTER ROLE visitaki_app SET idle_in_transaction_session_timeout='30s';
ALTER ROLE keycloak_visitaki_app SET idle_in_transaction_session_timeout='60s';
SELECT pg_advisory_unlock(hashtext('makepad-postgres'),hashtext('visitaki-bootstrap'));
\connect visitaki
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT ALL ON SCHEMA public TO visitaki_app;
\connect keycloak_visitaki
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT ALL ON SCHEMA public TO keycloak_visitaki_app;
