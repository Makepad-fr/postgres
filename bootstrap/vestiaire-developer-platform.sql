\set ON_ERROR_STOP on

-- Run with a PostgreSQL superuser connection. The application owns this
-- database; Flyway creates and evolves its tenant schema at startup.

\if :{?vestiaire_developer_app_password}
\else
  \echo 'missing required psql variable: vestiaire_developer_app_password'
  \quit 1
\endif

SELECT CASE
  WHEN NULLIF(btrim(:'vestiaire_developer_app_password'), '') IS NULL THEN 'false'
  ELSE 'true'
END AS vestiaire_developer_app_password_is_nonempty \gset
\if :vestiaire_developer_app_password_is_nonempty
\else
  \echo 'empty required psql variable: vestiaire_developer_app_password'
  \quit 1
\endif

SELECT pg_advisory_lock(
  hashtext('makepad-postgres'),
  hashtext('vestiaire-developer-platform-bootstrap')
);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vestiaire_developer_app') THEN
    CREATE ROLE vestiaire_developer_app LOGIN;
  END IF;
END;
$$;

ALTER ROLE vestiaire_developer_app
  LOGIN PASSWORD :'vestiaire_developer_app_password';

SELECT 'CREATE DATABASE vestiaire_developer OWNER vestiaire_developer_app'
WHERE NOT EXISTS (
  SELECT 1 FROM pg_database WHERE datname = 'vestiaire_developer'
) \gexec

SELECT 'ALTER DATABASE vestiaire_developer OWNER TO vestiaire_developer_app'
WHERE EXISTS (
  SELECT 1
  FROM pg_database d
  JOIN pg_roles r ON r.oid = d.datdba
  WHERE d.datname = 'vestiaire_developer'
    AND r.rolname <> 'vestiaire_developer_app'
) \gexec

GRANT CONNECT ON DATABASE vestiaire_developer TO vestiaire_developer_app;

SELECT pg_advisory_unlock(
  hashtext('makepad-postgres'),
  hashtext('vestiaire-developer-platform-bootstrap')
);
