\set ON_ERROR_STOP on
\if :{?carthop_app_password}
\else
  \echo 'missing carthop_app_password'
  \quit 1
\endif
SELECT length(:'carthop_app_password') >= 32 AS strong_password \gset
\if :strong_password
\else
  \echo 'carthop_app_password must contain at least 32 characters'
  \quit 1
\endif
SELECT pg_advisory_lock(hashtext('makepad-postgres'),hashtext('carthop-bootstrap'));
SELECT NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='carthop_app') AND NOT EXISTS(SELECT 1 FROM pg_database WHERE datname='carthop') AS fresh_install \gset
\if :fresh_install
CREATE ROLE carthop_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD :'carthop_app_password';
CREATE DATABASE carthop OWNER carthop_app;
REVOKE ALL ON DATABASE carthop FROM PUBLIC;
GRANT CONNECT ON DATABASE carthop TO carthop_app;
\else
  \echo 'CartHop database or role already exists. Existing ownership and credentials were not changed.'
\endif
SELECT pg_advisory_unlock(hashtext('makepad-postgres'),hashtext('carthop-bootstrap'));
