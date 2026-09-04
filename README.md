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
- `bootstrap/keycloak-new-instances.sql`: idempotent SQL bootstrap for the existing Vif, Makepad, Vestiaire, and Runtrace Keycloak databases
- `bootstrap/keycloak-runtrace-app.sql`: targeted idempotent bootstrap for the Runtrace Keycloak database
- `bootstrap/runtrace-app.sql`: idempotent SQL bootstrap for the Runtrace application database
- `bootstrap/openpanel-app.sql`: idempotent SQL bootstrap for the OpenPanel application database
- `bootstrap/brio-staging-app.sql`: idempotent SQL bootstrap for the Brio staging application database
- `bootstrap/keycloak-brio-staging.sql`: targeted idempotent bootstrap for Brio's Keycloak database
- `scripts/run-runtrace-backup.sh`: certificate-verified logical backup for Runtrace app and identity data
- `scripts/verify-runtrace-restore.sh`: destructive restore verification against explicit non-production targets
- `scripts/run-brio-encrypted-backup.sh`: streaming CMS-encrypted backup for one allowlisted Brio database
- `scripts/verify-brio-encrypted-restore.sh`: destructive two-database Brio restore verification
- `scripts/deploy-postgres-stack.sh`: checked-in remote Swarm preflight, deployment, convergence, and database-provisioning entrypoint

## Networks

The database joins external overlay networks configured through Compose:

- `${MAKEPAD_POSTGRES_DB_NETWORK}`
- `${MAKEPAD_POSTGRES_LE_PETIT_COIN_DB_NETWORK}`

Production also joins the VIF-specific external overlay network:

- `${MAKEPAD_POSTGRES_VIF_DB_NETWORK}`

Canary additionally joins Brio's staging-only, application-owned network:

- `${MAKEPAD_POSTGRES_BRIO_STAGING_DB_NETWORK}` (`makepad_brio_staging_db`)

The manual deploy workflow sources these Compose variables from environment secrets with this mapping:

- `${MAKEPAD_POSTGRES_DB_NETWORK}` <- `DEPLOY_CATWLK_DB_NETWORK`
- `${MAKEPAD_POSTGRES_LE_PETIT_COIN_DB_NETWORK}` <- `DEPLOY_LE_PETIT_COIN_DB_NETWORK`
- `${MAKEPAD_POSTGRES_VIF_DB_NETWORK}` <- `DEPLOY_VIF_DB_NETWORK` production only
- `${MAKEPAD_POSTGRES_BRIO_STAGING_DB_NETWORK}` <- `DEPLOY_BRIO_STAGING_DB_NETWORK` canary only

Every database network must be an attachable Swarm overlay created with `--opt encrypted`; Brio's dedicated network must additionally be `--internal`. The deploy workflow creates new networks with those properties and fails closed when an existing network does not match. To migrate an existing network, schedule a maintenance window, stop its dependent stacks, remove and recreate the network with the same name and required options, then redeploy PostgreSQL and the dependent stacks.

Application network topology is owned by the consuming application repositories. New Keycloak instances keep their own DB-facing Docker networks in the Keycloak repository and connect to this PostgreSQL server through the configured DB endpoint.

When using this repository's overlay-network deployment model, application stacks attached to the shared database network should use the stable service alias `makepad-postgres`. Le Petit Coin stacks attach through their app-specific database network and should use `makepad-postgres-le-petit-coin`. The production VIF stack attaches through its production-only app-specific database network and should use `makepad-postgres-vif`. Brio staging attaches only through `makepad_brio_staging_db` and verifies the alias `makepad-postgres-brio-staging`. Canary does not attach the VIF network. The current production Keycloak deployment is separate from this stack and uses the DB VM host address instead. The production override publishes PostgreSQL port 5432 in host mode so certificate-verified clients on the Keycloak and application VMs retain that endpoint while PostgreSQL remains pinned to the database node.

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
: "${MAKEPAD_POSTGRES_BRIO_IDENTITY_BACKUP_DB_HOST:?set to the DB certificate SAN hostname}"
docker compose --env-file envs/production/.env.db -f compose.host.yml config
docker compose --env-file envs/production/.env.db -f compose.host.yml up -d --pull always --remove-orphans --wait
```

The standalone DB-VM deployment additionally requires
`MAKEPAD_POSTGRES_BRIO_IDENTITY_BACKUP_DB_HOST` to be exported as the exact DB
VM hostname present in the PostgreSQL server certificate SAN. The encrypted
identity backup refuses any connection mode other than `verify-full`.

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

Canary additionally requires:

- `DEPLOY_BRIO_STAGING_DB_NETWORK` set exactly to `makepad_brio_staging_db`;
  the workflow rejects alternate names so Brio and PostgreSQL cannot drift onto
  disconnected look-alike networks

Production additionally requires:

- `DEPLOY_VIF_DB_NETWORK`
- `DEPLOY_VIF_DB_PASSWORD`

Production can override the VIF database and role names with `DEPLOY_VIF_DB_NAME` and `DEPLOY_VIF_DB_USER`; both default to `vif`.

`DEPLOY_SSH_USER` must be a non-root deployment account with the Docker permissions needed to create overlay networks and deploy the stack. The workflow rejects `DEPLOY_SSH_USER=root`.

Before the first deployment, provision the PostgreSQL superuser password as a non-empty root-owned file on the database node. The production default path is `/etc/makepad/secrets/postgres-superuser-password`; canary uses `/etc/makepad/secrets/postgres-canary-superuser-password`. Keep the file outside the repository, set mode `0600`, and override `MAKEPAD_POSTGRES_SUPERUSER_PASSWORD_FILE_HOST_PATH` only when the host secret manager materializes it elsewhere. PostgreSQL receives the value through `POSTGRES_PASSWORD_FILE`, and deployment helpers mount the same file read-only instead of placing the password in command arguments or tracked environment files.

Provision a private-CA-issued PostgreSQL server certificate before deployment. Its SANs must include every hostname clients verify, including `makepad-postgres`, `makepad-postgres-brio-staging`, and the DB VM hostname used by Keycloak. Keep the unencrypted private key outside git and create versioned Swarm objects on the database manager. Canary intentionally requires new `v2` objects so the older certificate cannot be reused without the Brio alias:

```sh
docker config create makepad_postgres_tls_cert_v1 /secure/path/server.crt
docker secret create makepad_postgres_tls_key_v1 /secure/path/server.key
docker config create makepad_postgres_canary_tls_cert_v2 /secure/path/canary-server.crt
docker secret create makepad_postgres_canary_tls_key_v2 /secure/path/canary-server.key
```

The names must match `MAKEPAD_POSTGRES_TLS_CERT_CONFIG` and `MAKEPAD_POSTGRES_TLS_KEY_SECRET` in the selected `.env.db`. Rotate by creating new versioned objects, updating those two names, and redeploying; never replace private-key material in place. Distribute only the issuing CA certificate to Runtrace, Brio, and Keycloak hosts. The deployment creates the versioned `MAKEPAD_POSTGRES_RUNTRACE_HBA_CONFIG` from the committed policy when absent and rejects content drift under an existing name. The policy rejects plaintext connections to `runtrace`, `keycloak_runtrace`, `brio_staging`, and `keycloak_brio_staging` and requires SCRAM authentication over TLS for those databases. Each Brio application and backup role is also rejected from every database except its named target; unrelated shared databases retain their current SCRAM transport policy during migration.

The workflow copies the checked-in remote deployment entrypoint with the deployment bundle and deploys only the PostgreSQL stack. Before deployment it validates
the password and CA files, certificate chain, seven-day expiry margin, and—for
canary—the exact `makepad-postgres-brio-staging` SAN. After the stack update it
performs a real `sslmode=verify-full` query over Brio's isolated network using
that alias; a certificate/key mismatch prevents PostgreSQL from becoming ready
and causes the canary service update to roll back. If one of the configured
database networks does not exist yet, it is created as an encrypted overlay on
the manager before deployment. After `docker stack deploy`, the workflow waits
until PostgreSQL and the environment's Brio backup service are running the exact
pinned image and the Swarm update has completed; only then does it run the TLS
database probe.

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

## Brio Encrypted Backup And Restore

Brio uses two isolated backup services because its staging application database
and Keycloak database live on different PostgreSQL deployments:

- Canary `brio_staging_backup` attaches only to `makepad_brio_staging_db`,
  connects as the read-only `brio_staging_backup` role, and dumps only
  `brio_staging` through `makepad-postgres-brio-staging`.
- The production/DB-VM `keycloak_brio_staging_backup` dumps only
  `keycloak_brio_staging` as the read-only
  `keycloak_brio_staging_backup` role. The Swarm form attaches only to the
  database network; the standalone DB-VM form uses the certificate-SAN hostname
  configured in `MAKEPAD_POSTGRES_BRIO_IDENTITY_BACKUP_DB_HOST`.

Both services use the pinned official
`postgres:16-bookworm@sha256:bb3e1a57e5407e0a5280b4211980a5e537f4abd234a87014ac979849a78dd825`
image, which supplies PostgreSQL 16 clients and OpenSSL. Each `pg_dump`
custom-format stream passes through a mode-0600 FIFO directly into an OpenSSL
CMS AES-256-GCM envelope. A plaintext dump is never written or published. Only
the encrypted `<database>.dump.cms`, checksummed metadata, and a health marker
are atomically published. Connections require `sslmode=verify-full`, backups
run every six hours, and timestamp directories are retained for exactly 35
days.

Create the X.509 encryption recipient and its private key in an offline recovery
environment. Install only the public recipient certificate on both database
hosts at `/etc/makepad/tls/backups/brio-recipient.crt`; the recovery private key
must never be copied to a database host, backup container, repository, CI
secret, or ordinary application secret store. Provision the service inputs:

```bash
# Canary application database host.
sudo install -d -o 999 -g 999 -m 0700 /var/lib/makepad/postgres-backups/brio-staging
sudo install -o 999 -g 999 -m 0400 /secure/path/brio-staging-backup-role-password \
  /etc/makepad/secrets/postgres-brio-app-backup-password

# Production identity database host.
sudo install -d -o 999 -g 999 -m 0700 /var/lib/makepad/postgres-backups/keycloak-brio-staging
sudo install -o 999 -g 999 -m 0400 /secure/path/keycloak-brio-staging-backup-role-password \
  /etc/makepad/secrets/postgres-brio-identity-backup-password

# Public encryption material only; retain the matching private key offline.
sudo install -d -o root -g root -m 0755 /etc/makepad/tls/backups
sudo install -o root -g root -m 0444 /secure/path/brio-recipient.crt \
  /etc/makepad/tls/backups/brio-recipient.crt
```

The Swarm deploy preflight copies the tracked backup scripts, rejects symlinked
inputs, requires each backup directory to be owned by uid 999 with mode 0700,
requires each database credential to be owned by uid 999 with mode 0400, and
requires a root-owned, non-writable public recipient certificate that remains
valid for at least seven days and can create a CMS AES-256-GCM envelope.
Each mounted credential is the password for its database-specific backup role;
never place a PostgreSQL superuser or application-owner password in either
backup credential file. The backup command refuses any role other than the
expected `brio_staging_backup` or `keycloak_brio_staging_backup` identity.

The host paths above are local staging artifacts, not disaster-recovery
storage. Replicate every completed timestamp directory and `last-success.json`
from each host to independently administered off-host storage without
decrypting it. Preserve the 35-day encrypted retention window there and alert
before either health marker exceeds two backup intervals.

Restore verification requires the newest application and identity timestamp
directories, an external copy of the public certificate and private key, two
explicit non-production libpq services, and a mode-0700 temporary directory.
Both libpq service names must end in `_restore_test` as an additional guard
against selecting an ordinary runtime service.
The temporary directory should be a dedicated tmpfs because it is the only
place where the verifier writes plaintext. The verifier checks the envelopes
and checksums before decrypting, validates each custom archive, restores with a
single transaction and exit-on-error, and requires `schema_migrations` plus
`communities` for Brio and `realm` for Keycloak:

```bash
export PGSERVICEFILE=/secure/restore/postgres-restore-services.conf
export BRIO_APP_RESTORE_SERVICE=brio_app_restore_test
export BRIO_KEYCLOAK_RESTORE_SERVICE=brio_keycloak_restore_test
export BRIO_RESTORE_RECIPIENT_CERT=/offline-recovery/brio-recipient.crt
export BRIO_RESTORE_RECIPIENT_KEY=/offline-recovery/brio-recipient.key
export BRIO_RESTORE_TEMP_ROOT=/run/brio-restore-tmpfs
export BRIO_RESTORE_CONFIRM=replace-nonproduction-brio-restore-targets
scripts/verify-brio-encrypted-restore.sh \
  /off-host/brio-staging/<timestamp> \
  /off-host/keycloak-brio-staging/<timestamp>
```

Keep the service file and recovery private key non-symlinked and accessible only
to the restore operator. Record the source timestamps, artifact checksums,
recipient-certificate fingerprint, target names, duration, result, and operator.
Off-host replication and a successful recorded restore of both databases remain
external release gates; repository tests cannot attest that those operational
steps occurred.

## Application Databases

Create one database and one dedicated user per application.

Vif, Makepad, Vestiaire, Runtrace, and Brio staging Keycloak use these databases and roles:

| Application | Database | Role |
| --- | --- | --- |
| Vif | `keycloak_vif` | `keycloak_vif_app` |
| Makepad | `keycloak_makepad` | `keycloak_makepad_app` |
| Vestiaire | `keycloak_vestiaire` | `keycloak_vestiaire_app` |
| Runtrace Keycloak | `keycloak_runtrace` | `keycloak_runtrace_app` |
| Brio staging Keycloak | `keycloak_brio_staging` | `keycloak_brio_staging_app` |

Runtrace application persistence uses:

| Application | Database | Role |
| --- | --- | --- |
| Runtrace app | `runtrace` | `runtrace_app` |

OpenPanel application persistence uses:

| Application | Database | Role |
| --- | --- | --- |
| OpenPanel app | `openpanel` | `openpanel_app` |

Brio staging application persistence and backups use:

| Purpose | Database | Role |
| --- | --- | --- |
| Brio staging app | `brio_staging` | `brio_staging_app` |
| Brio staging read-only backup | `brio_staging` | `brio_staging_backup` |
| Brio Keycloak read-only backup | `keycloak_brio_staging` | `keycloak_brio_staging_backup` |

Run the idempotent bootstrap with generated passwords. `POSTGRES_ADMIN_URL` must be a PostgreSQL superuser connection URI for the target server, usually using the `postgres` role, because the bootstrap creates roles, sets passwords, creates databases, and assigns database ownership. Run it on the database host over a Unix-domain socket, for example: `postgresql:///postgres?host=%2Fvar%2Frun%2Fpostgresql&user=postgres`. If remote administration is unavoidable, use the certificate-SAN hostname with `sslmode=verify-full`, the issuing CA, and a protected libpq password source. Both targeted Brio bootstraps inspect their own session and refuse a remote plaintext administrator session before changing any role or password.

```bash
: "${POSTGRES_ADMIN_URL:?set POSTGRES_ADMIN_URL to a PostgreSQL superuser connection URI}"
: "${KEYCLOAK_VIF_DB_PASSWORD:?set KEYCLOAK_VIF_DB_PASSWORD to a generated password}"
: "${KEYCLOAK_MAKEPAD_DB_PASSWORD:?set KEYCLOAK_MAKEPAD_DB_PASSWORD to a generated password}"
: "${KEYCLOAK_VESTIAIRE_DB_PASSWORD:?set KEYCLOAK_VESTIAIRE_DB_PASSWORD to a generated password}"
: "${KEYCLOAK_RUNTRACE_DB_PASSWORD:?set KEYCLOAK_RUNTRACE_DB_PASSWORD to a generated password}"
: "${RUNTRACE_DB_PASSWORD:?set RUNTRACE_DB_PASSWORD to a generated password}"
: "${OPENPANEL_DB_PASSWORD:?set OPENPANEL_DB_PASSWORD to a generated password}"
: "${BRIO_STAGING_DB_PASSWORD:?set BRIO_STAGING_DB_PASSWORD to a generated password}"
: "${BRIO_STAGING_BACKUP_DB_PASSWORD:?set BRIO_STAGING_BACKUP_DB_PASSWORD to a distinct generated password}"

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

: "${KEYCLOAK_BRIO_STAGING_DB_PASSWORD:?set KEYCLOAK_BRIO_STAGING_DB_PASSWORD to a generated password}"
: "${KEYCLOAK_BRIO_STAGING_BACKUP_DB_PASSWORD:?set KEYCLOAK_BRIO_STAGING_BACKUP_DB_PASSWORD to a distinct generated password}"
psql "$POSTGRES_ADMIN_URL" \
  -v keycloak_brio_staging_app_password="$KEYCLOAK_BRIO_STAGING_DB_PASSWORD" \
  -v keycloak_brio_staging_backup_password="$KEYCLOAK_BRIO_STAGING_BACKUP_DB_PASSWORD" \
  -f bootstrap/keycloak-brio-staging.sql

psql "$POSTGRES_ADMIN_URL" \
  -v openpanel_app_password="$OPENPANEL_DB_PASSWORD" \
  -f bootstrap/openpanel-app.sql

psql "$POSTGRES_ADMIN_URL" \
  -v brio_staging_app_password="$BRIO_STAGING_DB_PASSWORD" \
  -v brio_staging_backup_password="$BRIO_STAGING_BACKUP_DB_PASSWORD" \
  -f bootstrap/brio-staging-app.sql
```

The backup roles have no ownership or write privileges, default to read-only
transactions, and receive only schema usage plus `SELECT` on current and future
tables and sequences in their own database. Keep all four Brio credentials
distinct.

The current production Keycloak environments connect with the DB VM host:

```text
postgres://keycloak_vif_app:<secret>@<db-vm-host>:5432/keycloak_vif?sslmode=disable
postgres://keycloak_makepad_app:<secret>@<db-vm-host>:5432/keycloak_makepad?sslmode=disable
postgres://keycloak_vestiaire_app:<secret>@<db-vm-host>:5432/keycloak_vestiaire?sslmode=disable
postgres://keycloak_runtrace_app:<secret>@<db-vm-host>:5432/keycloak_runtrace?sslmode=verify-full&sslrootcert=/etc/makepad/tls/postgres/ca.crt
postgres://keycloak_brio_staging_app:<secret>@<db-vm-host>:5432/keycloak_brio_staging?sslmode=verify-full&sslrootcert=/etc/makepad/tls/postgres/ca.crt
postgres://runtrace_app:<secret>@<db-vm-host>:5432/runtrace?sslmode=verify-full&sslrootcert=/etc/runtrace/postgres/ca.crt
postgres://openpanel_app:<secret>@<db-vm-host>:5432/openpanel?schema=public&sslmode=disable
postgres://brio_staging_app:<secret>@makepad-postgres-brio-staging:5432/brio_staging?sslmode=verify-full&sslrootcert=/etc/brio/postgres/ca.crt
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

Brio staging uses only its isolated encrypted overlay and certificate-matching alias:

```text
postgres://brio_staging_app:<secret>@makepad-postgres-brio-staging:5432/brio_staging?sslmode=verify-full&sslrootcert=/etc/brio/postgres/ca.crt
```

If production overrides `DEPLOY_VIF_DB_NAME` or `DEPLOY_VIF_DB_USER`, use those values in the connection URI.

## Validation

Run the static deployment checks and the disposable PostgreSQL 16 bootstrap test:

```sh
./scripts/validate-postgres-config.sh
./scripts/test-brio-bootstrap.sh
./scripts/test-brio-encrypted-backup.sh
./scripts/test-brio-encrypted-restore.sh
```

Run the local static checks before opening a deployment PR:

```bash
bash scripts/validate-postgres-config.sh
bash scripts/test-runtrace-tls-policy.sh
bash scripts/test-runtrace-backup.sh
bash scripts/test-brio-encrypted-backup.sh
bash scripts/test-brio-encrypted-restore.sh
```
