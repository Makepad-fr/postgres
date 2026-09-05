#!/usr/bin/env bash
set -euo pipefail

if (($# != 3)); then
  echo "Usage: brio-db-transaction.sh <prepare|restore|fingerprint> <brio|keycloak> <journal-dir>" >&2
  exit 2
fi

operation=$1
scope=$2
journal_dir=$3

case "${operation}" in prepare|restore|fingerprint) ;; *) echo "Unsupported database transaction operation." >&2; exit 2 ;; esac
case "${scope}" in
  brio)
    database=brio_staging
    app_role=brio_staging_app
    backup_role=brio_staging_backup
    ;;
  keycloak)
    database=keycloak_brio_staging
    app_role=keycloak_brio_staging_app
    backup_role=keycloak_brio_staging_backup
    ;;
  *) echo "Unsupported Brio database transaction scope." >&2; exit 2 ;;
esac

[[ "${journal_dir}" == /* && -d "${journal_dir}" && ! -L "${journal_dir}" ]] || {
  echo "The database transaction journal must be a non-symlinked absolute directory." >&2
  exit 2
}
: "${PGUSER:?PGUSER is required}" "${PGHOST:?PGHOST is required}" "${PGPASSWORD_FILE:?PGPASSWORD_FILE is required}"
[[ -s "${PGPASSWORD_FILE}" && ! -L "${PGPASSWORD_FILE}" ]] || {
  echo "PGPASSWORD_FILE must be a non-empty regular file." >&2
  exit 2
}
export PGPASSWORD
PGPASSWORD=$(cat "${PGPASSWORD_FILE}")
export PGAPPNAME=brio-db-transaction PSQL_HISTORY=/dev/null

psql_base=(psql -X --no-password --set ON_ERROR_STOP=1 --quiet)

database_exists() {
  [[ $("${psql_base[@]}" --tuples-only --no-align --dbname postgres \
    --command "SELECT count(*) FROM pg_database WHERE datname = '${database}'") == 1 ]]
}

emit_fingerprint() {
  local db_exists=false role
  database_exists && db_exists=true
  printf 'scope\t%s\n' "${scope}"
  for role in "${app_role}" "${backup_role}"; do
    "${psql_base[@]}" --tuples-only --no-align --field-separator $'\t' --dbname postgres --command "
      SELECT 'role', rolname, rolsuper, rolinherit, rolcreaterole, rolcreatedb,
             rolcanlogin, rolreplication, rolconnlimit, coalesce(rolvaliduntil::text, '<null>'),
             rolbypassrls, coalesce(rolpassword, '<null>')
      FROM pg_authid WHERE rolname = '${role}';"
    "${psql_base[@]}" --tuples-only --no-align --field-separator $'\t' --dbname postgres --command "
      SELECT 'global-setting', r.rolname, setting
      FROM pg_db_role_setting s JOIN pg_roles r ON r.oid = s.setrole
      CROSS JOIN LATERAL unnest(s.setconfig) setting
      WHERE s.setdatabase = 0 AND r.rolname = '${role}' ORDER BY setting;"
  done
  printf 'database-exists\t%s\n' "${db_exists}"
  if [[ "${db_exists}" == true ]]; then
    "${psql_base[@]}" --tuples-only --no-align --field-separator $'\t' --dbname postgres --command "
      SELECT 'database', d.datname, r.rolname, d.datallowconn, d.datconnlimit,
             coalesce(d.datacl::text, '<null>')
      FROM pg_database d JOIN pg_roles r ON r.oid = d.datdba
      WHERE d.datname = '${database}';
      SELECT 'setting', role_name, setting
      FROM (
        SELECT r.rolname AS role_name, unnest(s.setconfig) AS setting
        FROM pg_db_role_setting s
        JOIN pg_roles r ON r.oid = s.setrole
        JOIN pg_database d ON d.oid = s.setdatabase
        WHERE d.datname = '${database}' AND r.rolname IN ('${app_role}', '${backup_role}')
      ) q ORDER BY role_name, setting;"
    "${psql_base[@]}" --tuples-only --no-align --field-separator $'\t' --dbname "${database}" --command "
      SELECT 'namespace', n.nspname, coalesce(n.nspacl::text, '<null>')
      FROM pg_namespace n WHERE n.nspname = 'public';
      SELECT 'relation', n.nspname, c.relname, c.relkind, coalesce(c.relacl::text, '<null>')
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relkind IN ('r','p','v','m','f','S')
      ORDER BY n.nspname, c.relname, c.relkind;
      SELECT 'default-acl', owner_name, schema_name, d.defaclobjtype,
             grantee_name, x.privilege_type, x.is_grantable
      FROM pg_default_acl d
      JOIN pg_roles owner_role ON owner_role.oid = d.defaclrole
      LEFT JOIN pg_namespace n ON n.oid = d.defaclnamespace
      CROSS JOIN LATERAL aclexplode(d.defaclacl) x
      LEFT JOIN pg_roles grantee_role ON grantee_role.oid = x.grantee
      CROSS JOIN LATERAL (VALUES(owner_role.rolname, coalesce(n.nspname, '<global>'),
        CASE WHEN x.grantee = 0 THEN 'PUBLIC' ELSE grantee_role.rolname END))
        names(owner_name, schema_name, grantee_name)
      WHERE owner_role.rolname = '${app_role}' AND coalesce(n.nspname, 'public') = 'public'
      ORDER BY owner_name, schema_name, d.defaclobjtype, grantee_name, x.privilege_type, x.is_grantable;"
  fi
}

write_role_restore() {
  local role=$1 output=$2 exists
  exists=$("${psql_base[@]}" --tuples-only --no-align --dbname postgres \
    --command "SELECT count(*) FROM pg_authid WHERE rolname = '${role}'")
  if [[ "${exists}" == 0 ]]; then
    printf 'DROP ROLE IF EXISTS %s;\n' "${role}" >> "${output}"
    return
  fi
  "${psql_base[@]}" --tuples-only --no-align --dbname postgres --command "
    SELECT format(
      'ALTER ROLE %I WITH %s %s %s %s %s %s CONNECTION LIMIT %s %s PASSWORD %L VALID UNTIL %L;',
      rolname,
      CASE WHEN rolsuper THEN 'SUPERUSER' ELSE 'NOSUPERUSER' END,
      CASE WHEN rolinherit THEN 'INHERIT' ELSE 'NOINHERIT' END,
      CASE WHEN rolcreaterole THEN 'CREATEROLE' ELSE 'NOCREATEROLE' END,
      CASE WHEN rolcreatedb THEN 'CREATEDB' ELSE 'NOCREATEDB' END,
      CASE WHEN rolcanlogin THEN 'LOGIN' ELSE 'NOLOGIN' END,
      CASE WHEN rolreplication THEN 'REPLICATION' ELSE 'NOREPLICATION' END,
      rolconnlimit,
      CASE WHEN rolbypassrls THEN 'BYPASSRLS' ELSE 'NOBYPASSRLS' END,
      rolpassword,
      coalesce(rolvaliduntil::text, 'infinity'))
    FROM pg_authid WHERE rolname = '${role}';
    SELECT format('UPDATE pg_authid SET rolvaliduntil = NULL WHERE rolname = %L;', rolname)
    FROM pg_authid WHERE rolname = '${role}' AND rolvaliduntil IS NULL;
    SELECT format('ALTER ROLE %I RESET ALL;', rolname)
    FROM pg_authid WHERE rolname = '${role}';
    SELECT format('ALTER ROLE %I SET %I TO %L;', r.rolname,
                  split_part(setting, '=', 1), substr(setting, strpos(setting, '=') + 1))
    FROM pg_db_role_setting s JOIN pg_roles r ON r.oid = s.setrole
    CROSS JOIN LATERAL unnest(s.setconfig) setting
    WHERE s.setdatabase = 0 AND r.rolname = '${role}' ORDER BY setting;" >> "${output}"
}

prepare_journal() {
  local restore_tmp="${journal_dir}/.restore.sql.tmp" fingerprint_tmp="${journal_dir}/.prestate.fingerprint.tmp"
  local restore_file="${journal_dir}/restore.sql" fingerprint_file="${journal_dir}/prestate.fingerprint"
  for path in "${restore_file}" "${fingerprint_file}" "${restore_tmp}" "${fingerprint_tmp}"; do
    [[ ! -e "${path}" && ! -L "${path}" ]] || { echo "Refusing to overwrite database journal material." >&2; exit 1; }
  done
  umask 077
  {
    printf '%s\n' '\set ON_ERROR_STOP on' 'SET client_min_messages = warning;'
    if database_exists; then
      printf '\\connect %s\n' "${database}"
      # These catalogs are the exact objects changed by the Brio bootstrap. The
      # fixed OID/name predicates make the compensation fail closed on drift.
      "${psql_base[@]}" --tuples-only --no-align --dbname "${database}" --command "
        SELECT format(
          'DO \$do\$ BEGIN IF NOT EXISTS (SELECT FROM pg_namespace WHERE oid = %s AND nspname = %L) THEN RAISE EXCEPTION ''namespace identity drift''; END IF; END \$do\$; UPDATE pg_namespace SET nspacl = %s WHERE oid = %s AND nspname = %L;',
          oid, nspname,
          CASE WHEN nspacl IS NULL THEN 'NULL' ELSE quote_literal(nspacl::text) || '::aclitem[]' END,
          oid, nspname)
        FROM pg_namespace WHERE nspname = 'public';
        SELECT format(
          'DO \$do\$ BEGIN IF NOT EXISTS (SELECT FROM pg_class WHERE oid = %s AND relnamespace = %s AND relname = %L AND relkind = %L) THEN RAISE EXCEPTION ''relation identity drift''; END IF; END \$do\$; UPDATE pg_class SET relacl = %s WHERE oid = %s AND relnamespace = %s AND relname = %L AND relkind = %L;',
          c.oid, c.relnamespace, c.relname, c.relkind,
          CASE WHEN c.relacl IS NULL THEN 'NULL' ELSE quote_literal(c.relacl::text) || '::aclitem[]' END,
          c.oid, c.relnamespace, c.relname, c.relkind)
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relkind IN ('r','p','v','m','f','S')
        ORDER BY c.oid;
        SELECT format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public REVOKE ALL ON %s FROM %I;',
                      '${app_role}', CASE defaclobjtype WHEN 'r' THEN 'TABLES' ELSE 'SEQUENCES' END, '${backup_role}')
        FROM (VALUES ('r'::\"char\"), ('S'::\"char\")) kinds(defaclobjtype);
        SELECT format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public GRANT %s ON %s TO %I%s;',
                      owner_role.rolname, string_agg(DISTINCT x.privilege_type, ', ' ORDER BY x.privilege_type),
                      CASE d.defaclobjtype WHEN 'r' THEN 'TABLES' ELSE 'SEQUENCES' END,
                      '${backup_role}', CASE WHEN bool_and(x.is_grantable) THEN ' WITH GRANT OPTION' ELSE '' END)
        FROM pg_default_acl d
        JOIN pg_roles owner_role ON owner_role.oid = d.defaclrole
        JOIN pg_namespace n ON n.oid = d.defaclnamespace
        CROSS JOIN LATERAL aclexplode(d.defaclacl) x
        JOIN pg_roles grantee_role ON grantee_role.oid = x.grantee
        WHERE owner_role.rolname = '${app_role}' AND n.nspname = 'public'
          AND grantee_role.rolname = '${backup_role}' AND d.defaclobjtype IN ('r','S')
        GROUP BY owner_role.rolname, d.defaclobjtype, x.is_grantable
        ORDER BY d.defaclobjtype, x.is_grantable;"
      printf '%s\n' '\connect postgres'
      "${psql_base[@]}" --tuples-only --no-align --dbname postgres --command "
        SELECT format('ALTER DATABASE %I OWNER TO %I;', d.datname, r.rolname)
        FROM pg_database d JOIN pg_roles r ON r.oid = d.datdba WHERE d.datname = '${database}';
        SELECT format('ALTER DATABASE %I %s; ALTER DATABASE %I CONNECTION LIMIT %s;',
                      datname, CASE WHEN datallowconn THEN 'ALLOW_CONNECTIONS true' ELSE 'ALLOW_CONNECTIONS false' END,
                      datname, datconnlimit)
        FROM pg_database WHERE datname = '${database}';
        SELECT format(
          'DO \$do\$ BEGIN IF NOT EXISTS (SELECT FROM pg_database WHERE oid = %s AND datname = %L) THEN RAISE EXCEPTION ''database identity drift''; END IF; END \$do\$; UPDATE pg_database SET datacl = %s WHERE oid = %s AND datname = %L;',
          oid, datname,
          CASE WHEN datacl IS NULL THEN 'NULL' ELSE quote_literal(datacl::text) || '::aclitem[]' END,
          oid, datname)
        FROM pg_database WHERE datname = '${database}';
        SELECT format('ALTER ROLE %I IN DATABASE %I RESET ALL;', r.rolname, d.datname)
        FROM pg_roles r CROSS JOIN pg_database d
        WHERE r.rolname IN ('${app_role}', '${backup_role}') AND d.datname = '${database}'
        ORDER BY r.rolname;
        SELECT format('ALTER ROLE %I IN DATABASE %I SET %I TO %L;', r.rolname, d.datname,
                      split_part(setting, '=', 1), substr(setting, strpos(setting, '=') + 1))
        FROM pg_db_role_setting s
        JOIN pg_roles r ON r.oid = s.setrole
        JOIN pg_database d ON d.oid = s.setdatabase
        CROSS JOIN LATERAL unnest(s.setconfig) setting
        WHERE r.rolname IN ('${app_role}', '${backup_role}') AND d.datname = '${database}'
        ORDER BY r.rolname, setting;"
    else
      printf "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '%s' AND pid <> pg_backend_pid();\n" "${database}"
      printf 'DROP DATABASE IF EXISTS %s;\n' "${database}"
    fi
  } > "${restore_tmp}"
  write_role_restore "${app_role}" "${restore_tmp}"
  write_role_restore "${backup_role}" "${restore_tmp}"
  emit_fingerprint > "${fingerprint_tmp}"
  chmod 0600 "${restore_tmp}" "${fingerprint_tmp}"
  mv -T "${restore_tmp}" "${restore_file}"
  mv -T "${fingerprint_tmp}" "${fingerprint_file}"
  sync -f "${journal_dir}" 2>/dev/null || sync
}

restore_journal() {
  [[ -s "${journal_dir}/restore.sql" && ! -L "${journal_dir}/restore.sql" \
    && -s "${journal_dir}/prestate.fingerprint" && ! -L "${journal_dir}/prestate.fingerprint" ]] || {
    echo "The database transaction journal is incomplete." >&2
    exit 1
  }
  "${psql_base[@]}" --dbname postgres --file "${journal_dir}/restore.sql" >/dev/null
  local restored="${journal_dir}/.restored.fingerprint.tmp"
  emit_fingerprint > "${restored}"
  if ! cmp -s "${journal_dir}/prestate.fingerprint" "${restored}"; then
    echo "Database compensation did not restore the exact prior Brio state." >&2
    # The fingerprint deliberately contains PostgreSQL SCRAM verifiers so the
    # recovery check can prove exact credential restoration. Never emit either
    # side of a mismatch: CI and remote deployment logs are not secret stores.
    rm -f -- "${restored}"
    exit 1
  fi
  rm -f -- "${restored}"
}

case "${operation}" in
  prepare) prepare_journal ;;
  restore) restore_journal ;;
  fingerprint) emit_fingerprint ;;
esac
