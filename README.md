# Makepad Postgres

Shared PostgreSQL deployment for Makepad-fr applications.

This repository owns the shared PostgreSQL server. Application repositories connect either through the shared overlay network alias or through the configured DB VM host endpoint, depending on their deployment topology. Application repositories should not deploy PostgreSQL directly in canary or production.

## Layout

- `compose.yml`: base PostgreSQL service definition
- `compose.host.yml`: TLS-enabled production Compose contract for the current dedicated DB VM
- `envs/canary/compose.yml`: canary Swarm overrides
- `envs/canary/.env.db`: canary PostgreSQL settings
- `envs/production/compose.yml`: production Swarm overrides
- `envs/production/.env.db`: production PostgreSQL settings
- `bootstrap/keycloak-new-instances.sql`: idempotent SQL bootstrap for the Vif, Makepad, Vestiaire, and Runtrace Keycloak databases
- `bootstrap/keycloak-runtrace-app.sql`: targeted idempotent bootstrap for the Runtrace Keycloak database
- `bootstrap/runtrace-app.sql`: idempotent SQL bootstrap for the Runtrace application database
- `bootstrap/openpanel-app.sql`: idempotent SQL bootstrap for the OpenPanel application database
- `bootstrap/amiary-apps.sql`: idempotent bootstrap for Amiary production, canary, and Keycloak databases
- `scripts/run-runtrace-backup.sh`: certificate-verified logical backup for Runtrace and Amiary app/identity data
- `scripts/verify-runtrace-restore.sh`: destructive restore verification for all covered databases against explicit non-production targets
- `scripts/preflight-postgres-major.sh`: fail-closed PostgreSQL 18 data-directory guard

## Networks

The database joins external overlay networks configured through Compose:

- `${MAKEPAD_POSTGRES_DB_NETWORK}`
- `${MAKEPAD_POSTGRES_LE_PETIT_COIN_DB_NETWORK}`

Production also joins the VIF-specific external overlay network:

- `${MAKEPAD_POSTGRES_VIF_DB_NETWORK}`

The manual deploy workflow sources these Compose variables from environment secrets with this mapping:

- `${MAKEPAD_POSTGRES_DB_NETWORK}` <- `DEPLOY_CATWLK_DB_NETWORK`
- `${MAKEPAD_POSTGRES_LE_PETIT_COIN_DB_NETWORK}` <- `DEPLOY_LE_PETIT_COIN_DB_NETWORK`
- `${MAKEPAD_POSTGRES_VIF_DB_NETWORK}` <- `DEPLOY_VIF_DB_NETWORK` production only

Every database network must be an attachable Swarm overlay created with `--opt encrypted`. The deploy workflow creates new networks with encryption and fails closed when an existing network is not encrypted. To migrate an existing network, schedule a maintenance window, stop its dependent stacks, remove and recreate the network with the same name and `--opt encrypted`, then redeploy PostgreSQL and the dependent stacks.

Application network topology is owned by the consuming application repositories. New Keycloak instances keep their own DB-facing Docker networks in the Keycloak repository and connect to this PostgreSQL server through the configured DB endpoint.

When using this repository's overlay-network deployment model, application stacks attached to the shared database network should use the stable service alias `makepad-postgres`. Le Petit Coin stacks attach through their app-specific database network and should use `makepad-postgres-le-petit-coin`. The production VIF stack attaches through its production-only app-specific database network and should use `makepad-postgres-vif`. Canary does not attach the VIF network. The current production Keycloak deployment is separate from this stack and uses the DB VM host address instead. The production override publishes PostgreSQL port 5432 in host mode so certificate-verified clients on the Keycloak and application VMs retain that endpoint while PostgreSQL remains pinned to the database node.

## Node Labels

Pin the shared PostgreSQL server to the dedicated database node:

```bash
docker node update --label-add infra.makepad.postgres=true <db-node>
```

## Deployment

Use the manual GitHub Actions workflow in this repository.

The dedicated database VM currently runs standalone Docker Compose rather than
joining the application Swarm. On that host, deploy the same TLS and backup
policy with `compose.host.yml` after provisioning the certificate, key, CA,
password files, backup directory, and committed HBA policy:

```bash
scripts/preflight-postgres-major.sh /var/lib/makepad/postgres 18
docker compose --env-file envs/production/.env.db -f compose.host.yml config
docker compose --env-file envs/production/.env.db -f compose.host.yml up -d --pull always --remove-orphans --wait
```

The repository is pinned to PostgreSQL 18. The preflight rejects a PostgreSQL
16 (or otherwise mismatched) data directory before Docker can start the new
major image. Existing installations must complete the reviewed logical upgrade
in `docs/postgresql-18-upgrade.md`; changing only the image is never supported.

The host deployment preserves the existing host-network endpoint used by
Keycloak while requiring TLS and SCRAM for `runtrace` and
`keycloak_runtrace`. Other databases keep their existing SCRAM transport policy.

Required environment secrets:

- `DEPLOY_SSH_HOST`
- `DEPLOY_SSH_PORT`
- `DEPLOY_SSH_USER`
- `DEPLOY_SSH_PRIVATE_KEY`
- `DEPLOY_SSH_KNOWN_HOSTS`
- `DEPLOY_REMOTE_DIR`
- `DEPLOY_STACK_NAME`
- `DEPLOY_CATWLK_DB_NETWORK`
- `DEPLOY_LE_PETIT_COIN_DB_NETWORK`

Production additionally requires:

- `DEPLOY_VIF_DB_NETWORK`
- `DEPLOY_VIF_DB_PASSWORD`
- `DEPLOY_STORAGEBOX_TRANSPORT_ENCRYPTION_CONFIRMED=true`
- `DEPLOY_STORAGEBOX_AT_REST_ENCRYPTION_CONFIRMED=true`

Production can override the VIF database and role names with `DEPLOY_VIF_DB_NAME` and `DEPLOY_VIF_DB_USER`; both default to `vif`.

`DEPLOY_SSH_USER` must be a non-root deployment account with the Docker permissions needed to create overlay networks and deploy the stack. The workflow rejects `DEPLOY_SSH_USER=root`.

Before the first deployment, provision the PostgreSQL superuser password as a non-empty root-owned file on the database node. The production default path is `/etc/makepad/secrets/postgres-superuser-password`; canary uses `/etc/makepad/secrets/postgres-canary-superuser-password`. Keep the file outside the repository, set mode `0600`, and override `MAKEPAD_POSTGRES_SUPERUSER_PASSWORD_FILE_HOST_PATH` only when the host secret manager materializes it elsewhere. PostgreSQL receives the value through `POSTGRES_PASSWORD_FILE`, and deployment helpers mount the same file read-only instead of placing the password in command arguments or tracked environment files.

Provision a private-CA-issued PostgreSQL server certificate before deployment. Its SANs must include every hostname clients verify, including `makepad-postgres` and the DB VM hostname used by Keycloak. Keep the unencrypted private key outside git and create versioned Swarm objects on the database manager:

```sh
docker config create makepad_postgres_tls_cert_v1 /secure/path/server.crt
docker secret create makepad_postgres_tls_key_v1 /secure/path/server.key
```

The names must match `MAKEPAD_POSTGRES_TLS_CERT_CONFIG` and `MAKEPAD_POSTGRES_TLS_KEY_SECRET` in the selected `.env.db`. Rotate by creating new versioned objects, updating those two names, and redeploying; never replace private-key material in place. Distribute only the issuing CA certificate to application and Keycloak hosts. The deployment creates the versioned `MAKEPAD_POSTGRES_RUNTRACE_HBA_CONFIG` from the committed policy when absent and rejects content drift under an existing name. The current `v4` policy adds Amiary and the dedicated backup identity to the prior Runtrace policy, rejects plaintext connections to all Runtrace and Amiary application/identity databases, requires SCRAM authentication over TLS, and rejects every Amiary or backup login from unrelated databases even if an older database still grants `PUBLIC CONNECT`; unrelated shared identities retain their current SCRAM transport policy during migration.

The same committed HBA policy explicitly rejects plaintext access to `amiary`, `amiary_canary`, and `keycloak_amiary`, and requires SCRAM over TLS for all three.

The workflow deploys only the PostgreSQL stack. It validates the password file before deployment. If one of the configured database networks does not exist yet, it is created as an encrypted overlay on the manager before deployment.

## Shared Backup And Restore

Production runs a dedicated unprivileged backup service on the PostgreSQL node. Its `makepad_backup` login is `NOINHERIT`, has `CONNECT` only to the five protected databases, and can assume the non-login `makepad_backup_reader` without admin rights solely when `pg_dump` passes `--role=makepad_backup_reader`. The reader inherits `pg_read_all_data` and has `BYPASSRLS`, which is necessary to capture forced-RLS rows, but receives no write or administrative capability. It connects with `sslmode=verify-full`, creates PostgreSQL custom-format dumps for `runtrace`, `keycloak_runtrace`, `amiary`, `amiary_canary`, and `keycloak_amiary`, preserves object owners and ACLs, validates each archive with `pg_restore --list`, writes SHA-256 checksums, and publishes a health timestamp. The first backup runs when the service starts; later backups run every six hours by default and are retained for 35 days.

Before production deployment, mount the Hetzner Storage Box at
`/mnt/makepad-storagebox` using authenticated encrypted transport and ensure its
storage is encrypted at rest. The deploy workflow requires explicit
confirmations, verifies that this is a real mountpoint, and rejects any backup
path outside it. A directory on the same physical data disk is not a
disaster-recovery backup. Provision the backup directory and the independently
generated `makepad_backup` password for container uid 70; never copy the
PostgreSQL superuser credential into this file:

```bash
sudo install -d -o 70 -g 70 -m 0700 /mnt/makepad-storagebox/postgres
sudo install -o 70 -g 70 -m 0400 /secure/path/makepad-backup-password \
  /etc/makepad/secrets/postgres-backup-password
```

The production deploy preflight rejects a missing/symlinked backup path, a
non-mounted Storage Box, a path outside that mount, incorrect owner or mode, an
invalid credential file, and a missing or writable PostgreSQL CA. The backup
service writes each verified six-hour snapshot directly to the off-host mount
and retains it for 35 days. Monitor `runtrace_backup` health and
`last-success.json`; alert before freshness exceeds two backup intervals.

At least quarterly, and before a paid launch or material database upgrade, restore the newest backup into five empty non-production databases. Pre-provision the original owner/grantee role names with the reviewed bootstraps; restore deliberately fails if ownership or ACL metadata cannot be applied. Put certificate-verified connection and password settings in a root-owned libpq service file so credentials do not appear in process arguments, then run:

```bash
export PGSERVICEFILE=/etc/makepad/postgres-restore-services.conf
export RUNTRACE_RESTORE_SERVICE=runtrace_restore_test
export KEYCLOAK_RUNTRACE_RESTORE_SERVICE=keycloak_runtrace_restore_test
export AMIARY_RESTORE_SERVICE=amiary_restore_test
export AMIARY_CANARY_RESTORE_SERVICE=amiary_canary_restore_test
export KEYCLOAK_AMIARY_RESTORE_SERVICE=keycloak_amiary_restore_test
export RUNTRACE_RESTORE_CONFIRM=replace-nonproduction-restore-targets
scripts/verify-runtrace-restore.sh /mnt/makepad-storagebox/postgres/<timestamp>
```

Record the timestamp, artifact checksum, duration, and operator in shared backup/restore evidence. The restore verifier intentionally refuses to run without the exact non-production replacement acknowledgement and validates the Runtrace, Amiary, and Keycloak durable schemas, SECURITY DEFINER owners, and forced-RLS flags after restore.

## Application Databases

Create an isolated database and dedicated login roles per application.

Vif, Makepad, Vestiaire, and Runtrace Keycloak use these databases and roles:

| Application | Database | Role |
| --- | --- | --- |
| Vif | `keycloak_vif` | `keycloak_vif_app` |
| Makepad | `keycloak_makepad` | `keycloak_makepad_app` |
| Vestiaire | `keycloak_vestiaire` | `keycloak_vestiaire_app` |
| Runtrace Keycloak | `keycloak_runtrace` | `keycloak_runtrace_app` |

Runtrace application persistence uses:

| Application | Database | Role |
| --- | --- | --- |
| Runtrace app | `runtrace` | `runtrace_app` |

OpenPanel application persistence uses:

| Application | Database | Role |
| --- | --- | --- |
| OpenPanel app | `openpanel` | `openpanel_app` |

Run the idempotent bootstrap with generated passwords. `POSTGRES_ADMIN_URL` must be a PostgreSQL superuser connection URI for the target server, usually using the `postgres` role, because the bootstrap creates roles, sets passwords, creates databases, and assigns database ownership. For example: `postgres://postgres@<db-vm-host>:5432/postgres?sslmode=disable`.

For Amiary, use separate production and canary login roles for migrations, the
API, and the graph worker. Shared `NOLOGIN` roles carry object privileges while
the environment-specific logins carry credentials and database access:

| Environment | Database | Purpose | Login role | Membership / ownership |
| --- | --- | --- | --- | --- |
| Production | `amiary` | Migrations | `amiary_migrator` | Database owner; may `SET ROLE amiary_security_definer` |
| Production | `amiary` | API | `amiary_api_prod` | Inherits `amiary_api`; direct `CONNECT` only |
| Production | `amiary` | Graph worker | `amiary_worker_prod` | Inherits `amiary_worker`; direct `CONNECT` only |
| Canary | `amiary_canary` | Migrations | `amiary_canary_migrator` | Database owner; may `SET ROLE amiary_security_definer` |
| Canary | `amiary_canary` | API | `amiary_api_canary` | Inherits `amiary_api`; direct `CONNECT` only |
| Canary | `amiary_canary` | Graph worker | `amiary_worker_canary` | Inherits `amiary_worker`; direct `CONNECT` only |
| Identity | `keycloak_amiary` | Keycloak | `keycloak_amiary_app` | Database owner; no Amiary capability membership |
| Shared | Five protected databases | Backup | `makepad_backup` | `NOINHERIT`; may `SET ROLE makepad_backup_reader`; HBA-denied elsewhere |

`amiary_api` and `amiary_worker` are constrained `NOLOGIN NOBYPASSRLS` roles.
Application migrations grant them only the schema, table, sequence, and
function privileges each service needs. `amiary_security_definer` is a
`NOLOGIN BYPASSRLS` function-owner role with no database `CONNECT`; it is not
granted to API, worker, or Keycloak logins. Only the two migrators receive a
non-inherited, non-admin membership that permits an explicit `SET ROLE` while
installing reviewed security-definer functions.

Generate eight independent passwords and provision the three databases plus
the shared read-only backup login:

```bash
: "${POSTGRES_ADMIN_URL:?set POSTGRES_ADMIN_URL to a PostgreSQL superuser connection URI}"
: "${AMIARY_MIGRATOR_DB_PASSWORD:?set AMIARY_MIGRATOR_DB_PASSWORD to a generated password}"
: "${AMIARY_API_DB_PASSWORD:?set AMIARY_API_DB_PASSWORD to a generated password}"
: "${AMIARY_WORKER_DB_PASSWORD:?set AMIARY_WORKER_DB_PASSWORD to a generated password}"
: "${AMIARY_CANARY_MIGRATOR_DB_PASSWORD:?set AMIARY_CANARY_MIGRATOR_DB_PASSWORD to a generated password}"
: "${AMIARY_CANARY_API_DB_PASSWORD:?set AMIARY_CANARY_API_DB_PASSWORD to a generated password}"
: "${AMIARY_CANARY_WORKER_DB_PASSWORD:?set AMIARY_CANARY_WORKER_DB_PASSWORD to a generated password}"
: "${KEYCLOAK_AMIARY_DB_PASSWORD:?set KEYCLOAK_AMIARY_DB_PASSWORD to a generated password}"
: "${MAKEPAD_BACKUP_DB_PASSWORD:?set MAKEPAD_BACKUP_DB_PASSWORD to a generated password}"

psql "${POSTGRES_ADMIN_URL}" \
  -v amiary_migrator_password="${AMIARY_MIGRATOR_DB_PASSWORD}" \
  -v amiary_api_prod_password="${AMIARY_API_DB_PASSWORD}" \
  -v amiary_worker_prod_password="${AMIARY_WORKER_DB_PASSWORD}" \
  -v amiary_canary_migrator_password="${AMIARY_CANARY_MIGRATOR_DB_PASSWORD}" \
  -v amiary_api_canary_password="${AMIARY_CANARY_API_DB_PASSWORD}" \
  -v amiary_worker_canary_password="${AMIARY_CANARY_WORKER_DB_PASSWORD}" \
  -v keycloak_amiary_app_password="${KEYCLOAK_AMIARY_DB_PASSWORD}" \
  -v makepad_backup_password="${MAKEPAD_BACKUP_DB_PASSWORD}" \
  -f bootstrap/amiary-apps.sql
```

The bootstrap removes public database privileges, repairs role and ownership
drift on every run, and grants API/worker logins only `CONNECT` to their own
environment. Application schema migrations remain in `Makepad-fr/amiary`.

Use the purpose-specific DSN; never run the API or worker through a migrator
connection. The CA path below is the backend container contract:

```text
postgres://amiary_migrator:<secret>@<db-vm-host>:5432/amiary?sslmode=verify-full&sslrootcert=/run/secrets/database_ca
postgres://amiary_api_prod:<secret>@<db-vm-host>:5432/amiary?sslmode=verify-full&sslrootcert=/run/secrets/database_ca
postgres://amiary_worker_prod:<secret>@<db-vm-host>:5432/amiary?sslmode=verify-full&sslrootcert=/run/secrets/database_ca
postgres://amiary_canary_migrator:<secret>@<db-vm-host>:5432/amiary_canary?sslmode=verify-full&sslrootcert=/run/secrets/database_ca
postgres://amiary_api_canary:<secret>@<db-vm-host>:5432/amiary_canary?sslmode=verify-full&sslrootcert=/run/secrets/database_ca
postgres://amiary_worker_canary:<secret>@<db-vm-host>:5432/amiary_canary?sslmode=verify-full&sslrootcert=/run/secrets/database_ca
postgres://keycloak_amiary_app:<secret>@<db-vm-host>:5432/keycloak_amiary?sslmode=verify-full&sslrootcert=/run/secrets/database_ca
postgres://makepad_backup:<secret>@<db-vm-host>:5432/amiary?sslmode=verify-full&sslrootcert=/run/secrets/database_ca
```

```bash
: "${POSTGRES_ADMIN_URL:?set POSTGRES_ADMIN_URL to a PostgreSQL superuser connection URI}"
: "${KEYCLOAK_VIF_DB_PASSWORD:?set KEYCLOAK_VIF_DB_PASSWORD to a generated password}"
: "${KEYCLOAK_MAKEPAD_DB_PASSWORD:?set KEYCLOAK_MAKEPAD_DB_PASSWORD to a generated password}"
: "${KEYCLOAK_VESTIAIRE_DB_PASSWORD:?set KEYCLOAK_VESTIAIRE_DB_PASSWORD to a generated password}"
: "${KEYCLOAK_RUNTRACE_DB_PASSWORD:?set KEYCLOAK_RUNTRACE_DB_PASSWORD to a generated password}"
: "${RUNTRACE_DB_PASSWORD:?set RUNTRACE_DB_PASSWORD to a generated password}"
: "${OPENPANEL_DB_PASSWORD:?set OPENPANEL_DB_PASSWORD to a generated password}"

psql "$POSTGRES_ADMIN_URL" \
  -v keycloak_vif_app_password="$KEYCLOAK_VIF_DB_PASSWORD" \
  -v keycloak_makepad_app_password="$KEYCLOAK_MAKEPAD_DB_PASSWORD" \
  -v keycloak_vestiaire_app_password="$KEYCLOAK_VESTIAIRE_DB_PASSWORD" \
  -v keycloak_runtrace_app_password="$KEYCLOAK_RUNTRACE_DB_PASSWORD" \
  -f bootstrap/keycloak-new-instances.sql

psql "$POSTGRES_ADMIN_URL" \
  -v runtrace_app_password="$RUNTRACE_DB_PASSWORD" \
  -f bootstrap/runtrace-app.sql

# Use this targeted bootstrap when the other Keycloak databases already exist.
psql "$POSTGRES_ADMIN_URL" \
  -v keycloak_runtrace_app_password="$KEYCLOAK_RUNTRACE_DB_PASSWORD" \
  -f bootstrap/keycloak-runtrace-app.sql

psql "$POSTGRES_ADMIN_URL" \
  -v openpanel_app_password="$OPENPANEL_DB_PASSWORD" \
  -f bootstrap/openpanel-app.sql
```

The current production Keycloak environments connect with the DB VM host:

```text
postgres://keycloak_vif_app:<secret>@<db-vm-host>:5432/keycloak_vif?sslmode=disable
postgres://keycloak_makepad_app:<secret>@<db-vm-host>:5432/keycloak_makepad?sslmode=disable
postgres://keycloak_vestiaire_app:<secret>@<db-vm-host>:5432/keycloak_vestiaire?sslmode=disable
postgres://keycloak_runtrace_app:<secret>@<db-vm-host>:5432/keycloak_runtrace?sslmode=verify-full&sslrootcert=/etc/makepad/tls/postgres/ca.crt
postgres://runtrace_app:<secret>@<db-vm-host>:5432/runtrace?sslmode=verify-full&sslrootcert=/etc/runtrace/postgres/ca.crt
postgres://openpanel_app:<secret>@<db-vm-host>:5432/openpanel?schema=public&sslmode=disable
```

Stacks deployed through this repository's shared overlay network should use the `makepad-postgres` alias instead:

```text
postgres://keycloak_vif_app:<secret>@makepad-postgres:5432/keycloak_vif?sslmode=disable
postgres://keycloak_makepad_app:<secret>@makepad-postgres:5432/keycloak_makepad?sslmode=disable
postgres://keycloak_vestiaire_app:<secret>@makepad-postgres:5432/keycloak_vestiaire?sslmode=disable
postgres://keycloak_runtrace_app:<secret>@makepad-postgres:5432/keycloak_runtrace?sslmode=verify-full&sslrootcert=/etc/makepad/tls/postgres/ca.crt
postgres://runtrace_app:<secret>@makepad-postgres:5432/runtrace?sslmode=verify-full&sslrootcert=/etc/runtrace/postgres/ca.crt
postgres://openpanel_app:<secret>@makepad-postgres:5432/openpanel?schema=public&sslmode=disable
```

Le Petit Coin uses the app-specific overlay alias:

```text
postgres://le_petit_coin_canary_app:<secret>@makepad-postgres-le-petit-coin:5432/le_petit_coin_canary?sslmode=disable
postgres://le_petit_coin_app:<secret>@makepad-postgres-le-petit-coin:5432/le_petit_coin?sslmode=disable
```

The production VIF app uses its app-specific overlay alias and deploy-time provisioned database:

```text
postgres://vif:<secret>@makepad-postgres-vif:5432/vif?sslmode=disable
```

If production overrides `DEPLOY_VIF_DB_NAME` or `DEPLOY_VIF_DB_USER`, use those values in the connection URI.

## Validation

Run the local static checks before opening a deployment PR:

```bash
bash scripts/validate-postgres-config.sh
bash scripts/test-runtrace-tls-policy.sh
bash scripts/test-runtrace-backup.sh
bash scripts/test-shared-restore.sh
bash scripts/validate-amiary-config.sh
bash scripts/test-amiary-bootstrap.sh
```
