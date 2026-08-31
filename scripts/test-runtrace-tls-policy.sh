#!/usr/bin/env bash
set -euo pipefail

for binary in docker openssl; do
  if ! command -v "${binary}" >/dev/null 2>&1; then
    echo "Missing required binary for PostgreSQL TLS test: ${binary}" >&2
    exit 1
  fi
done

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "${script_dir}/.." && pwd)
postgres_image=${POSTGRES_IMAGE:-postgres:18-alpine@sha256:d3e1620b530c944afa6e887d22eb899824da68e19c52024bf98f5220c88a65b2}
suffix="${RANDOM}-$$"
container_name="runtrace-postgres-tls-${suffix}"
network_name="runtrace-postgres-tls-${suffix}"
volume_name="runtrace-postgres-tls-${suffix}"
server_name=runtrace-postgres-test
password="runtrace-tls-test-${suffix}"
temp_dir=$(mktemp -d)

cleanup() {
  docker rm -f "${container_name}" >/dev/null 2>&1 || true
  docker network rm "${network_name}" >/dev/null 2>&1 || true
  docker volume rm "${volume_name}" >/dev/null 2>&1 || true
  rm -rf "${temp_dir}"
}
trap cleanup EXIT

cat > "${temp_dir}/server.conf" <<EOF
[req]
distinguished_name = distinguished_name
req_extensions = extensions
prompt = no

[distinguished_name]
CN = ${server_name}

[extensions]
subjectAltName = DNS:${server_name}
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -days 1 -nodes \
  -subj "/CN=Runtrace PostgreSQL test CA" \
  -keyout "${temp_dir}/ca.key" -out "${temp_dir}/ca.crt" >/dev/null 2>&1
openssl req -newkey rsa:2048 -sha256 -nodes \
  -config "${temp_dir}/server.conf" \
  -keyout "${temp_dir}/server.key" -out "${temp_dir}/server.csr" >/dev/null 2>&1
openssl x509 -req -sha256 -days 1 \
  -in "${temp_dir}/server.csr" \
  -CA "${temp_dir}/ca.crt" -CAkey "${temp_dir}/ca.key" -CAcreateserial \
  -extfile "${temp_dir}/server.conf" -extensions extensions \
  -out "${temp_dir}/server.crt" >/dev/null 2>&1
cp "${repo_root}/config/runtrace-pg_hba.conf" "${temp_dir}/pg_hba.conf"

docker network create "${network_name}" >/dev/null
docker volume create "${volume_name}" >/dev/null
docker run --rm --entrypoint sh \
  -v "${volume_name}:/target" \
  -v "${temp_dir}:/source:ro" \
  "${postgres_image}" -ec '
    cp /source/server.crt /target/server.crt
    cp /source/server.key /target/server.key
    cp /source/pg_hba.conf /target/pg_hba.conf
    chown 70:70 /target/server.crt /target/server.key /target/pg_hba.conf
    chmod 0444 /target/server.crt /target/pg_hba.conf
    chmod 0400 /target/server.key
  '

docker run -d --name "${container_name}" \
  --network "${network_name}" --network-alias "${server_name}" \
  -e "POSTGRES_USER=runtrace_app" \
  -e "POSTGRES_PASSWORD=${password}" \
  -e "POSTGRES_DB=runtrace" \
  -v "${volume_name}:/run/postgres-tls:ro" \
  "${postgres_image}" \
  postgres \
  -c ssl=on \
  -c ssl_cert_file=/run/postgres-tls/server.crt \
  -c ssl_key_file=/run/postgres-tls/server.key \
  -c hba_file=/run/postgres-tls/pg_hba.conf >/dev/null

ready=false
for _ in $(seq 1 30); do
  if docker exec "${container_name}" pg_isready -U runtrace_app -d runtrace >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
if [[ "${ready}" != "true" ]]; then
  docker logs "${container_name}" >&2
  echo "PostgreSQL TLS test instance did not become ready." >&2
  exit 1
fi

docker exec "${container_name}" psql -v ON_ERROR_STOP=1 -U runtrace_app -d runtrace \
  -c "CREATE ROLE makepad_backup LOGIN PASSWORD 'backup-${password}' NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS; GRANT CONNECT ON DATABASE runtrace TO makepad_backup" >/dev/null

tls_result=$(docker run --rm --network "${network_name}" \
  -e "PGPASSWORD=${password}" \
  -v "${temp_dir}/ca.crt:/run/test-ca.crt:ro" \
  "${postgres_image}" psql \
  "host=${server_name} user=runtrace_app dbname=runtrace sslmode=verify-full sslrootcert=/run/test-ca.crt" \
  -Atc "select ssl from pg_stat_ssl where pid = pg_backend_pid()")
if [[ "${tls_result}" != "t" ]]; then
  echo "Certificate-verified Runtrace database connection was not encrypted." >&2
  exit 1
fi

if docker run --rm --network "${network_name}" \
  -e "PGPASSWORD=${password}" \
  "${postgres_image}" psql \
  "host=${server_name} user=runtrace_app dbname=runtrace sslmode=disable" \
  -Atc "select 1" >/dev/null 2>&1; then
  echo "Plaintext access to the Runtrace database unexpectedly succeeded." >&2
  exit 1
fi

backup_tls_result=$(docker run --rm --network "${network_name}" \
  -e "PGPASSWORD=backup-${password}" \
  -v "${temp_dir}/ca.crt:/run/test-ca.crt:ro" \
  "${postgres_image}" psql \
  "host=${server_name} user=makepad_backup dbname=runtrace sslmode=verify-full sslrootcert=/run/test-ca.crt" \
  -Atc "select current_user")
if [[ "${backup_tls_result}" != "makepad_backup" ]]; then
  echo "Dedicated backup login could not reach an approved database over verified TLS." >&2
  exit 1
fi

if docker run --rm --network "${network_name}" \
  -e "PGPASSWORD=backup-${password}" \
  -v "${temp_dir}/ca.crt:/run/test-ca.crt:ro" \
  "${postgres_image}" psql \
  "host=${server_name} user=makepad_backup dbname=postgres sslmode=verify-full sslrootcert=/run/test-ca.crt" \
  -Atc "select 1" >/dev/null 2>&1; then
  echo "Dedicated backup login reached an unrelated database." >&2
  exit 1
fi

legacy_result=$(docker run --rm --network "${network_name}" \
  -e "PGPASSWORD=${password}" \
  "${postgres_image}" psql \
  "host=${server_name} user=runtrace_app dbname=postgres sslmode=disable" \
  -Atc "select 1")
if [[ "${legacy_result}" != "1" ]]; then
  echo "The scoped Runtrace HBA policy unexpectedly blocked a non-Runtrace database." >&2
  exit 1
fi

echo "Runtrace PostgreSQL TLS policy test passed."
