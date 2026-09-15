\set ON_ERROR_STOP on
\if :{?scan_app_password}
\else
  \echo 'missing scan_app_password'
  \quit 1
\endif
SELECT length(:'scan_app_password') >= 32 AS strong_password \gset
\if :strong_password
\else
  \echo 'scanner password must contain at least 32 characters'
  \quit 1
\endif
SELECT pg_advisory_lock(hashtext('makepad-postgres'), hashtext('makepad-scan-bootstrap'));
SELECT format('CREATE ROLE makepad_scan_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD %L', :'scan_app_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='makepad_scan_app') \gexec
SELECT 'CREATE DATABASE makepad_scan OWNER makepad_scan_app'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='makepad_scan') \gexec
REVOKE ALL ON DATABASE makepad_scan FROM PUBLIC;
GRANT CONNECT ON DATABASE makepad_scan TO makepad_scan_app;
SELECT pg_advisory_unlock(hashtext('makepad-postgres'), hashtext('makepad-scan-bootstrap'));
\connect makepad_scan
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE, CREATE ON SCHEMA public TO makepad_scan_app;
