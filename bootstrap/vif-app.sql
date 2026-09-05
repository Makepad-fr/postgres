\set ON_ERROR_STOP on

\if :{?vif_db}
\else
  \echo 'missing required psql variable: vif_db'
  SELECT 1 / 0;
\endif

\if :{?vif_user}
\else
  \echo 'missing required psql variable: vif_user'
  SELECT 1 / 0;
\endif

\getenv vif_password VIF_PASSWORD
SELECT CASE WHEN NULLIF(btrim(:'vif_password'), '') IS NULL THEN 'false' ELSE 'true' END AS vif_password_is_nonempty \gset
\if :vif_password_is_nonempty
\else
  \echo 'empty required environment variable: VIF_PASSWORD'
  SELECT 1 / 0;
\endif

SELECT format('CREATE ROLE %I LOGIN', :'vif_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'vif_user') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'vif_user', :'vif_password') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'vif_db', :'vif_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'vif_db') \gexec
SELECT format('ALTER DATABASE %I OWNER TO %I', :'vif_db', :'vif_user')
WHERE EXISTS (
  SELECT 1
  FROM pg_database d
  JOIN pg_roles r ON r.oid = d.datdba
  WHERE d.datname = :'vif_db'
    AND r.rolname <> :'vif_user'
) \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'vif_db', :'vif_user') \gexec
