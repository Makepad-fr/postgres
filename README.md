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
- `scripts/run-runtrace-backup.sh`: certificate-verified logical backup for Runtrace app and identity data
- `scripts/verify-runtrace-restore.sh`: destructive restore verification against explicit non-production targets

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
docker compose --env-file envs/production/.env.db -f compose.host.yml config
docker compose --env-file envs/production/.env.db -f compose.host.yml up -d --pull always --remove-orphans --wait
```

The host deployment preserves the existing host-network endpoint used by
Keycloak while requiring TLS and SCRAM for `runtrace` and
`keycloak_runtrace`. Other databases keep their existing SCRAM transport policy.

Required environment secrets:

- `DEPLOY_SSH_HOST`
- `DEPLOY_SSH_PORT`
- `DEPLOY_SSH_USER`
- `DEPLOY_SSH_PRIVATE_KEY`
- `DEPLOY_REMOTE_DIR`
- `DEPLOY_STACK_NAME`
- `DEPLOY_CATWLK_DB_NETWORK`
- `DEPLOY_LE_PETIT_COIN_DB_NETWORK`

Production additionally requires:

- `DEPLOY_VIF_DB_NETWORK`
- `DEPLOY_VIF_DB_PASSWORD`

Production can override the VIF database and role names with `DEPLOY_VIF_DB_NAME` and `DEPLOY_VIF_DB_USER`; both default to `vif`.

`DEPLOY_SSH_USER` must be a non-root deployment account with the Docker permissions needed to create overlay networks and deploy the stack. The workflow rejects `DEPLOY_SSH_USER=root`.

Before the first deployment, provision the PostgreSQL superuser password as a non-empty root-owned file on the database node. The production default path is `/etc/makepad/secrets/postgres-superuser-password`; canary uses `/etc/makepad/secrets/postgres-canary-superuser-password`. Keep the file outside the repository, set mode `0600`, and override `MAKEPAD_POSTGRES_SUPERUSER_PASSWORD_FILE_HOST_PATH` only when the host secret manager materializes it elsewhere. PostgreSQL receives the value through `POSTGRES_PASSWORD_FILE`, and deployment helpers mount the same file read-only instead of placing the password in command arguments or tracked environment files.

Provision a private-CA-issued PostgreSQL server certificate before deployment. Its SANs must include every hostname clients verify, including `makepad-postgres` and the DB VM hostname used by Keycloak. Keep the unencrypted private key outside git and create versioned Swarm objects on the database manager:

```sh
docker config create makepad_postgres_tls_cert_v1 /secure/path/server.crt
docker secret create makepad_postgres_tls_key_v1 /secure/path/server.key
```

The names must match `MAKEPAD_POSTGRES_TLS_CERT_CONFIG` and `MAKEPAD_POSTGRES_TLS_KEY_SECRET` in the selected `.env.db`. Rotate by creating new versioned objects, updating those two names, and redeploying; never replace private-key material in place. Distribute only the issuing CA certificate to Runtrace and Keycloak hosts. The deployment creates the versioned `MAKEPAD_POSTGRES_RUNTRACE_HBA_CONFIG` from the committed policy when absent and rejects content drift under an existing name. The policy rejects plaintext connections to `runtrace` and `keycloak_runtrace` and requires SCRAM authentication over TLS for both; unrelated shared databases retain their current SCRAM transport policy during migration.

The workflow deploys only the PostgreSQL stack. It validates the password file before deployment. If one of the configured database networks does not exist yet, it is created as an encrypted overlay on the manager before deployment.

## Runtrace Backup And Restore

Production runs a dedicated unprivileged backup service on the PostgreSQL node. It connects with `sslmode=verify-full`, creates PostgreSQL custom-format dumps for both `runtrace` and `keycloak_runtrace`, validates each archive with `pg_restore --list`, writes SHA-256 checksums, and publishes a health timestamp. The first backup runs when the service starts; later backups run every six hours by default and are retained for 35 days.

Before production deployment, provision the backup directory and a dedicated copy of the PostgreSQL superuser credential for container uid 70. The backup directory must be on storage that is replicated or transferred off the database node; a directory on the same physical data disk is not a disaster-recovery backup.

```bash
sudo install -d -o 70 -g 70 -m 0700 /var/lib/makepad/postgres-backups/runtrace
sudo install -o 70 -g 70 -m 0400 /secure/path/postgres-superuser-password \
  /etc/makepad/secrets/postgres-backup-password
```

The production deploy preflight rejects a missing/symlinked backup path, incorrect owner or mode, an invalid credential file, and a missing or writable PostgreSQL CA. Monitor the `runtrace_backup` service health and copy each completed timestamp directory plus `last-success.json` to an independently administered storage account. Alert before the health timestamp exceeds two backup intervals.

At least quarterly, and before a paid launch or material database upgrade, restore the newest backup into two empty non-production databases. Put certificate-verified connection and password settings in a root-owned libpq service file so credentials do not appear in process arguments, then run:

```bash
export PGSERVICEFILE=/etc/makepad/postgres-restore-services.conf
export RUNTRACE_RESTORE_SERVICE=runtrace_restore_test
export KEYCLOAK_RUNTRACE_RESTORE_SERVICE=keycloak_runtrace_restore_test
export RUNTRACE_RESTORE_CONFIRM=replace-nonproduction-restore-targets
scripts/verify-runtrace-restore.sh /var/lib/makepad/postgres-backups/runtrace/<timestamp>
```

Record the timestamp, artifact checksum, duration, and operator in Runtrace backup/restore evidence. The restore verifier intentionally refuses to run without the exact non-production replacement acknowledgement and validates that both durable state schemas exist after restore.

## Application Databases

Create one database and one dedicated user per application.

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
```
