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
- `bootstrap/vif-app.sql`: VIF application bootstrap that reads its password only through `\getenv`
- `scripts/run-runtrace-backup.sh`: certificate-verified logical backup for Runtrace app and identity data
- `scripts/verify-runtrace-restore.sh`: destructive restore verification against explicit non-production targets
- `scripts/run-brio-encrypted-backup.sh`: streaming CMS-encrypted backup for one allowlisted Brio database
- `scripts/verify-brio-encrypted-restore.sh`: destructive two-database Brio restore verification
- `scripts/deploy-postgres-stack.sh`: checked-in remote Swarm preflight, deployment, convergence, and database-provisioning entrypoint
- `scripts/deploy-brio-canary-postgres.sh`: prevalidated, snapshot-backed canary host/Swarm transaction, Brio bootstrap, access probes, and backup verification
- `scripts/deploy-brio-identity-db-host.sh`: guarded standalone DB-VM snapshot, durable recovery evidence, rollback, HBA update, Brio identity bootstrap, access probes, and backup verification
- `scripts/ensure-brio-tmp-cleaner.sh`: persistent host guard that expires abandoned Brio deployment directories after three hours while preserving recovery-marked runs
- `scripts/install-keycloak-cohort-capture-host.sh`: idempotent root installer for the digest-bound cohort SSH forced command and persistent file/Docker-resource cleaner
- `scripts/clean-keycloak-cohort-resources.sh`: fail-closed cleanup of expired labeled cohort containers, networks, and dump directories
- `scripts/test-brio-deployment-failures.sh`: isolated behavioral fault tests for promotion, stack, signal, rollback, evidence-retention, and symlink failures

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

Every database network must be an attachable Swarm overlay created with `--opt encrypted=true`; Brio's dedicated network must additionally be `--internal`. The explicit value matters: Docker records a valueless `--opt encrypted` as an empty option rather than the required `true`. The deploy workflow creates new networks with those properties and fails closed when an existing network does not match. To migrate an existing network, schedule a maintenance window, stop its dependent stacks, remove and recreate the network with the same name and required options, then redeploy PostgreSQL and the dependent stacks.

Application network topology is owned by the consuming application repositories. New Keycloak instances keep their own DB-facing Docker networks in the Keycloak repository and connect to this PostgreSQL server through the configured DB endpoint.

When using this repository's overlay-network deployment model, application stacks attached to the shared database network should use the stable service alias `makepad-postgres`. Le Petit Coin stacks attach through their app-specific database network and should use `makepad-postgres-le-petit-coin`. The production VIF stack attaches through its production-only app-specific database network and should use `makepad-postgres-vif`. Brio staging attaches only through `makepad_brio_staging_db` and verifies the alias `makepad-postgres-brio-staging`. Canary does not attach the VIF network. The current production Keycloak deployment is separate from this stack and uses the DB VM host address instead. The production override publishes PostgreSQL port 5432 in host mode so certificate-verified clients on the Keycloak and application VMs retain that endpoint while PostgreSQL remains pinned to the database node.

## Node Labels

Pin the shared PostgreSQL server to the dedicated database node:

```bash
docker node update --label-add infra.makepad.postgres=true <db-node>
```

## Deployment

Use the manual GitHub Actions workflow in this repository for Swarm canary and
ordinary shared-stack deployments. Brio's topology is deliberately split:
`brio_staging` belongs to the canary application Swarm, while
`keycloak_brio_staging` is provisioned only by the separate `Deploy Brio
Identity Database` workflow on the standalone database VM. The production
Swarm override contains no Brio identity backup service and must never be used
to bootstrap or back up the Brio Keycloak database.

Both deployment workflows require the protected `Postgres Deploy` runner group
and repository-scoped `makepad-postgres-deploy` label. Protected-main CI uses
the separate `Postgres Main CI` group and `makepad-postgres-main-ci` label.
Pull-request code is never executed on either persistent host; the disposable
PR boundary is documented below. A generic Makepad runner cannot execute these
jobs. Both deployment workflows also reject every Git ref except `main`;
configure the GitHub environments with the same deployment-branch restriction
and required reviewers.

Swarm deployments share one target-wide concurrency group across canary and
production. Every run uploads to a unique
`<DEPLOY_REMOTE_DIR>/.deploy/postgres-<run>-<attempt>` bundle; no workflow writes
a shared remote `stack.yml`. Before credentials are uploaded, both deployment
paths install or validate a restricted, restartable host cleaner. It removes
only abandoned top-level `/tmp/postgres-brio-*` directories older than three
hours, covering runner interruption or loss of the SSH session in addition to
the workflows' immediate `always()` cleanup.

The dedicated database VM currently runs standalone Docker Compose rather than
joining the application Swarm. Do not run the following recovery-level command
for the ordinary Brio identity rollout; the protected workflow supplies and
validates the reviewed inputs:

```bash
: "${MAKEPAD_POSTGRES_BRIO_IDENTITY_BACKUP_DB_HOST:?set to the DB certificate SAN hostname}"
docker compose --env-file envs/production/.env.db -f compose.host.yml config
docker compose --env-file envs/production/.env.db -f compose.host.yml up -d --pull always --remove-orphans --wait
```

The standalone DB-VM deployment additionally requires
`MAKEPAD_POSTGRES_BRIO_IDENTITY_BACKUP_DB_HOST` to be exported as the exact DB
VM host or IP present in the PostgreSQL server certificate SAN. The encrypted
identity backup refuses any connection mode other than `verify-full`.
The current host private key contract is numeric owner/group `70:70`, mode
`0400`; the deploy preflight requires that exact verified live form without
copying the key into CI.
The workflow also refuses a Swarm node, pins Compose project `postgres`, and
requires the existing `postgres-postgres-1` container to have the exact Compose
project/service labels, host networking, pinned image, healthy state, and
`/var/lib/makepad/postgres:/var/lib/postgresql/data` read-write bind. It requires an exact restart
acknowledgement and confirmation of a current successful encrypted restore
test, and renders the Keycloak application HBA rule to one verified egress
`/32`. Candidate Compose, HBA, SQL, and scripts are staged and prevalidated.
Immediately before the first managed-file mutation, the deploy snapshots the
exact prior Compose inputs, HBA, scripts, affected backup credentials, and the
complete standalone Brio identity backup directory. Any
error or `HUP`/`INT`/`TERM` after that boundary restores the snapshot, recreates
the prior Compose project, and requires the exact PostgreSQL target to return
healthy. The candidate promotion recreates the fixed Compose project so the
updated bind-mounted HBA is loaded, then verifies TLS identity, plaintext rejection,
cross-database rejection, read-only backup access, and a newly published CMS
backup. The rollback is disarmed only after all those local probes and the fresh
encrypted backup pass. Local DB-VM probes and the host-network backup container set
`PGHOSTADDR=127.0.0.1` while retaining the certificate host in `PGHOST`, so
transport is deterministically local while `verify-full` still checks the
declared DNS or IP SAN. The identity backup HBA rule is correspondingly limited
to `127.0.0.1/32`; only the Keycloak application role receives the separately
rendered egress `/32` rule.

The host deployment preserves the existing host-network endpoint used by
Keycloak while requiring TLS and SCRAM for `runtrace`, `keycloak_runtrace`,
`fresko_production`, `betacrew`, and `keycloak_betacrew`. Fresko's runtime,
schema-owner, and importer roles and the BetaCrew application role are limited
to the private WireGuard source `10.80.0.1/32`; the BetaCrew Keycloak role is
limited to `88.99.209.165/32`, with local maintenance access limited to
`127.0.0.1/32`. The committed HBA policy rejects every other source or plaintext
connection for those databases before reaching the shared fallback. Other
databases keep their existing SCRAM transport policy.

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

Canary additionally requires:

- `DEPLOY_BRIO_STAGING_DB_NETWORK` set exactly to `makepad_brio_staging_db`;
  the workflow rejects alternate names so Brio and PostgreSQL cannot drift onto
  disconnected look-alike networks
- `POSTGRES_CANARY_SUPERUSER_PASSWORD`
- `POSTGRES_CA_PEM`
- `POSTGRES_SERVER_CERT_PEM`, whose SAN includes
  `makepad-postgres-brio-staging`
- `POSTGRES_SERVER_KEY_PEM`, matching that certificate
- `BRIO_STAGING_DB_PASSWORD`
- `BRIO_STAGING_BACKUP_DB_PASSWORD`
- `BRIO_BACKUP_RECIPIENT_CERT_PEM`, containing only the public recovery
  certificate

The canary workflow materializes these only in mode-0700 job directories with
mode-0600 files, transfers them to one job-scoped remote `/tmp` directory,
and removes local and remote job material in `always()` cleanup steps. Before
any mutation it validates exact managed destinations (including every existing
path component), immutable object digests, all network contracts, the current
stack identity, and both Compose and Swarm renderings. It atomically publishes
a root-owned transaction journal under
`/var/lib/makepad/postgres-recovery/brio-canary/<run>-<attempt>` containing the
exact managed-file, database, ACL/default-privilege, backup-directory, and
Swarm service pre-state. Replacements are staged beside their destinations and
promoted with same-filesystem renames. Any later error or signal restores the
database and host snapshot, rolls back each changed pre-existing service once
and verifies its exact prior Spec hash, and removes only objects labeled with
the current deployment ID. A SIGKILL leaves the journal for mandatory recovery
at the beginning of the next deployment. A failed compensation leaves
`RECOVERY_REQUIRED`; normal workflow and TTL cleanup preserve it. Passwords
are read from mounted files inside short-lived containers and never placed in
Docker or `psql` command arguments.

Canary acceptance uses a hardened one-shot backup container and does not force
a second update of the PostgreSQL or backup Swarm service. Because `docker
stack deploy` does not prune a service removed from a Compose file, a legacy
`${stack}_keycloak_brio_staging_backup` service causes deployment to fail
closed. Inventory its exact Spec and retire that exact service only through a
separately reviewed operation after the standalone `keycloak_brio_staging`
backup has been accepted; never use a broad stack prune for this migration.

The protected `staging-brio-identity-db` GitHub environment requires:

- secrets `BRIO_IDENTITY_DB_DEPLOY_SSH_HOST`,
  `BRIO_IDENTITY_DB_DEPLOY_SSH_PORT`,
  `BRIO_IDENTITY_DB_DEPLOY_SSH_USER`,
  `BRIO_IDENTITY_DB_DEPLOY_SSH_PRIVATE_KEY`, and
  `BRIO_IDENTITY_DB_DEPLOY_SSH_KNOWN_HOSTS`
- secrets `KEYCLOAK_BRIO_STAGING_DB_PASSWORD`,
  `KEYCLOAK_BRIO_STAGING_BACKUP_DB_PASSWORD`, and
  `BRIO_BACKUP_RECIPIENT_CERT_PEM`
- variable `BRIO_IDENTITY_DB_HOSTNAME`, equal to the server-certificate SAN
  used by Keycloak for the standalone DB endpoint; the current value is
  `65.21.134.125`, which is present as an IP SAN in the deployed certificate
- variable `BRIO_KEYCLOAK_DB_SOURCE_CIDR`, equal to Keycloak's verified single
  database egress `/32` (currently `88.99.209.165/32`); the Brio WireGuard
  tunnel is for Keycloak-to-MailDev traffic and is not a database route

Protect that environment with required reviewers. Dispatch `Deploy Brio
Identity Database` from `main`, type
`restart-standalone-postgres-for-brio-staging`, and confirm the restore gate
only after recording a successful restore of the current encrypted backup.
The SSH account must be non-root but has Docker access, which is root-equivalent
and therefore restricted to this reviewed deployment path.

All Brio workflow-supplied deployment, release, and CI credentials have one
canonical Proton Pass item and are copied only into the named, protected
GitHub environment. They are not repository or organization secrets, runner
configuration, or files on a persistent runner. Existing shared PostgreSQL
production credentials keep their established Proton items; this rollout does
not rename or duplicate them. Non-secret deployment constants remain protected
GitHub environment variables. The exact Brio inventory is:

| Canonical Proton Pass item | Protected GitHub environment | Exact mirrored fields |
| --- | --- | --- |
| `Hetzner App Server makepad` | `canary` and `production` | native fields `host`, `port`, `user`, `private_key`, and `known_hosts` map to the five `DEPLOY_SSH_*` destinations for the application Swarm manager required by `manual-deploy.yml` |
| `Hetzner Database Server makepad` | `staging-brio-identity-db` and `keycloak-cohort-restore` | canonical custom fields `DEPLOY_SSH_HOST`, `DEPLOY_SSH_PORT`, `DEPLOY_SSH_USER`, `DEPLOY_SSH_PRIVATE_KEY`, and `DEPLOY_SSH_KNOWN_HOSTS` map to the workflow aliases `BRIO_IDENTITY_DB_DEPLOY_SSH_*` and `KEYCLOAK_COHORT_DB_SSH_*` only in their named standalone DB-host environments |
| `PostgreSQL · shared Swarm deployment` | `canary` and `production` | current workflow-compatible protected fields for the PostgreSQL remote directory, stack, Catwlk network, and production-only VIF database name, role, network, and password; exact destinations are in `deploy/credential-inventory.json` |
| `Le Petit Coin GitHub Deploy Secrets` | `canary` and `production` | canonical `DEPLOY_DB_NETWORK` maps to the PostgreSQL workflow alias `DEPLOY_LE_PETIT_COIN_DB_NETWORK`, keeping both stacks on the same application-owned database overlay |
| `Brio Staging - PostgreSQL` | `canary`; Keycloak passwords only in `staging-brio-identity-db` | `canary` secrets `DEPLOY_BRIO_STAGING_DB_NETWORK`, `POSTGRES_CANARY_SUPERUSER_PASSWORD`, `BRIO_STAGING_DB_PASSWORD`, and `BRIO_STAGING_BACKUP_DB_PASSWORD`; only `KEYCLOAK_BRIO_STAGING_DB_PASSWORD` and `KEYCLOAK_BRIO_STAGING_BACKUP_DB_PASSWORD` are mirrored to `staging-brio-identity-db` |
| Name-only retained destinations | No Proton field and no write authority | Existing `staging-brio-identity-db` secrets `BRIO_STAGING_DB_PASSWORD` and `BRIO_STAGING_BACKUP_DB_PASSWORD`, plus variable `POSTGRES_HOST_COMPOSE_PROJECT`; report and preserve pending an explicitly authorized provider cleanup |
| `Brio Staging - PKI and Backup Keys` | `canary`; recipient certificate only in `staging-brio-identity-db` | `canary` secrets `POSTGRES_CA_PEM`, `POSTGRES_SERVER_CERT_PEM`, `POSTGRES_SERVER_KEY_PEM`, and `BRIO_BACKUP_RECIPIENT_CERT_PEM`; only `BRIO_BACKUP_RECIPIENT_CERT_PEM` is mirrored to `staging-brio-identity-db` |
| `PostgreSQL · Brio identity release orchestrator` | `release-brio-identity-db` | secret `KEYCLOAK_RELEASE_ORCHESTRATOR_TOKEN` |
| `PostgreSQL · Keycloak cohort source reader` | `keycloak-cohort-restore` | secret `KEYCLOAK_COHORT_SOURCE_TOKEN` |
| `Makepad Docker Hardened Images` | `keycloak-cohort-restore` | canonical fields `DOCKERHUB_USERNAME` and `DOCKERHUB_PRO_PAT`, mirrored as secrets `DHI_REGISTRY_USERNAME` and `DHI_REGISTRY_PASSWORD` |
| `PostgreSQL · PR Checks App` | `postgres-ci-attestation` and repository policy | secret `POSTGRES_PR_CHECK_APP_PRIVATE_KEY` in the environment; public repository variable `POSTGRES_PR_CHECK_APP_ID` |
| `PostgreSQL · JIT Launcher App` | repository policy only | public repository variable `POSTGRES_CI_LAUNCHER_APP_SENDER_ID`; private App fields remain on the controller host only |
| `PostgreSQL · JIT hypervisor attestation` | repository policy only | public repository variables `POSTGRES_CI_ATTESTATION_PUBLIC_KEY` and `POSTGRES_CI_APPROVED_BASE_IMAGE_SHA256`; the signing key remains on the hypervisor only |
| `PostgreSQL · GitHub repository variable bootstrap` | operator workstation only | field `repository_variable_admin_token` is supplied process-locally to `gh` only during the explicit four-variable sync; `owner` and `expires_at` remain operator verification records |

The first two name-only entries are environment-scope duplicates: their active
workflow destinations are the identically named `canary` secrets, while the
identity workflow consumes only the Keycloak-role passwords. The Compose
project selector has no workflow consumer because the DB-host deploy pins
project `postgres` in code. The sync helper never reads, writes, or deletes
these three names, and it still rejects every other unlisted destination.

The identity DB hostname and Keycloak source CIDR are protected environment
variables. The current shared-Swarm workflow still consumes its remote path,
stack, network, VIF database name, and VIF role through the existing protected
secret namespace; the machine-readable inventory preserves that exact
workflow contract until a coordinated workflow/provider migration. None of
these values may be copied to repository secrets.

The machine-readable mapping and fail-closed operator procedure are documented
in [`docs/credential-sync.md`](docs/credential-sync.md). Use `pass-cli` from an
approved administrator workstation and stream secret values over standard
input:

```bash
pass-cli item view --item-title '<item>' --field '<field>' \
  | gh secret set '<NAME>' --env '<environment>' --repo 'Makepad-fr/postgres'
```

Never place values in command arguments, temporary files, shell history,
Actions logs, or issue text. Mirror the four non-secret repository trust
anchors only through the explicitly bounded command below; it validates their
provider IDs, lowercase SHA-256 digest, and Ed25519 public key before stdin-only
writes, then compares two GitHub read-backs exactly with Proton. The helper
refuses ambient GitHub authentication for those mutations: first create the
canonical `PostgreSQL · GitHub repository variable bootstrap` Proton item with
`repository_variable_admin_token`, `owner`, and `expires_at`. Its short-lived
fine-grained credential is limited to `Makepad-fr/postgres` with repository
Variables write and Metadata read, and is revoked after the exact read-back:

```bash
./scripts/sync-github-environments.sh --sync-repository-variables \
  --confirm Makepad-fr/postgres:repository-variables
```

Record only item IDs, field names, timestamps, and non-secret fingerprints in the deployment
change record. Every listed environment, including `production`, must have
exactly one custom branch deployment policy whose type is `branch` and whose
name is exactly `main`; GitHub's generic "protected branches" option is not an
equivalent restriction. A release is blocked if an item or field is missing,
if that exact policy or required reviewers are absent, or if GitHub differs
from the reviewed Proton version.

Audit all six policies without changing provider state:

```bash
python3 scripts/reconcile-github-environment-main-policy.py audit
```

The policy matrix requires GitHub user `idilsaglam` (immutable user ID
`39597780`), prevents self-review, and uses a zero-minute wait timer for
`canary`, `production`, `staging-brio-identity-db`,
`release-brio-identity-db`, and `keycloak-cohort-restore`. The sole deliberate
exception is `postgres-ci-attestation`: its exact-main signed machine result
must not deadlock waiting for a human deployment approval, so it has no
reviewer and no wait timer.

Reconcile one environment only after reviewing its current protection rules.
The helper snapshots the pinned reviewer identity, refuses unknown rules,
applies the exact matrix, verifies its immediate read-back, creates the exact
`main` branch rule before removing broader custom rules, and then verifies the
final policy and reviewer identity again. Applying requires an explicit
repository/environment confirmation; for production use:

```bash
python3 scripts/reconcile-github-environment-main-policy.py apply \
  --environment production \
  --confirm Makepad-fr/postgres:production:protected-policy-v1
```

Run this only from an administrator workstation whose `gh` session has
environment-administration permission. The helper never reads or writes
environment secrets.

Host-only JIT Launcher, attestation-signing, runner-controller, and alert
credentials are also canonical in the Proton items documented below, but are
intentionally never copied into Actions; only their public identities and
reviewed digests are mirrored to `postgres-ci-attestation`.

If automatic standalone rollback cannot re-establish the exact healthy target,
the deploy script first deletes all incoming job credentials, then retains a
root-owned mode-0700 recovery bundle under
`/var/lib/makepad/postgres-recovery/brio-identity/<run>-<attempt>` and leaves a
non-secret `RECOVERY_REQUIRED` marker in the run-scoped `/tmp` directory. The
workflow and three-hour cleaner deliberately skip that marked directory.
Operators must inspect and resolve the retained evidence from the DB VM, then
remove both exact run directories only after recovery is complete. The bundle
may contain the former managed backup credential and must never be copied into
Actions artifacts or ordinary logs.

The database-VM workflow's local probes do not prove the public route from the
Keycloak host. Release is deliberately two-phase. A successful `Deploy Brio
Identity Database` run stops after uploading exactly one 35-day artifact named
`brio-db-deployment-evidence-<run>-<attempt>` containing the single canonical
`brio-db-deployment-evidence.json` file. That artifact says only that the
standalone host deployment is ready; it never claims Keycloak-path success.

A reviewer then dispatches the separate protected `Release Brio Identity
Database` workflow with that exact PostgreSQL run ID and attempt. The protected
`release-brio-identity-db` environment supplies the dedicated
`KEYCLOAK_RELEASE_ORCHESTRATOR_TOKEN`. Its canonical credential must first be
stored in Proton Pass item `PostgreSQL · Brio identity release orchestrator`,
then mirrored only to that protected environment. Use a dedicated fine-grained
token or short-lived installation-token broker restricted to exactly
`Makepad-fr/postgres` and `Makepad-fr/keycloak`, with Metadata read, Contents
read, and Actions read/write; it must have no Administration, Environments,
Secrets, Members, Packages, Deployments, or organization-runner permission and
must never be an ambient maintainer PAT. Record the App installation or token
owner and a non-secret fingerprint in the same Proton item. The orchestrator independently requires the
PostgreSQL run to be completed successfully on `main`, fully paginates and validates the exact
artifact name, size, one-file ZIP shape, schema, commit, run, and attempt,
resolves the current exact Keycloak `main` SHA, and dispatches
`Makepad-fr/keycloak/.github/workflows/verify-brio-database.yml`. It accepts
only the exact completed verifier run and its single
`brio-db-path-attestation-<verifier-run>-<attempt>` artifact; it never creates,
copies, or synthesizes an attestation itself.
The bearer credential is supplied to each API request through curl's stdin-only
configuration and is never materialized in the persistent runner filesystem.

The protected `Verify Brio Identity Database Path` workflow has the run name
`Verify Brio DB path for PostgreSQL run <postgres-run-id>` and publishes the
`brio-db-path-ok` evidence. Its dedicated Keycloak runner verifies
`sslmode=verify-full` to `65.21.134.125`, the certificate IP SAN, exact
database/role, TLS 1.2 or 1.3, and server-observed source `88.99.209.165`; no
Keycloak database credential is granted to the PostgreSQL runner.

Pull requests use protected-base `pull_request_target` workflow code and reject
forks before checking out the exact same-repository head. The public repository
does not have a persistent PR runner. A dedicated root-only hypervisor queue
controller authorizes the exact queued run, attempt, job, PR head, PR base SHA,
protected workflow SHA, group, and label through GitHub's APIs. It durably
records a deterministic launch/resource manifest before launch, obtains a
one-job JIT configuration, and boots a fresh
self-contained qcow2 VM with the exclusive
`makepad-postgres-pr-ephemeral` label. The hypervisor firewall denies private,
WireGuard, link-local, metadata, multicast, IPv6, and hypervisor destinations;
only public DNS and TLS egress are allowed. The guest contains no repository,
deployment, Proton Pass, App, SSH, cloud, or service credential.

After the job stops, the hypervisor destroys and proves absent the VM, disk,
cloud-init seed, network, firewall table, and GitHub runner registration. Only
then may it sign canonical `makepad.postgres.ci-attestation.v1` evidence with
its root-only Ed25519 key and dispatch it with the dedicated Launcher App. A
physically separate `makepad-postgres-ci-attestor` host in the selected-workflow
`org/Postgres PR Ephemeral` group runs only protected
`pr-ci-result.yml`; it has no Docker, deployment, or Launcher credentials. It
verifies the immutable numeric Launcher-App sender ID, signature, freshness,
nonce replay, reviewed base-image digest, exact authoritative run/job/runner
identity and conclusion, all teardown flags, and an independent 404 lookup for
the removed runner before the Checks-only App can publish the required
`postgres-ci` result. Failed or uncertain cleanup never produces a successful
check. Main pushes run independently on `org/Postgres Main CI`. The systemd
service uses control-group termination. On every controller start, all
`launching` or `recovery-required` records are reconciled before queue polling:
the exact VM, network, nftables table, job directory, and named runner
registration must all be proven absent. Recovered jobs are never executed or
attested again. Authoritative run/job completion is polled for a bounded period
after teardown to tolerate API propagation without rerunning untrusted code.

Reconcile the four exact selected-workflow groups with
`scripts/configure-postgres-ci-runner-group.sh`, streaming its organization
runner-controller credential on stdin. Because `Makepad-fr/postgres` is public,
the groups explicitly allow public repositories but select only this exact
repository and protected-main workflow files. Repository-level runners and
runners exposed by unrelated groups are rejected. No persistent runner may
carry the JIT-only label. Install and supervise
`host/systemd/postgres-ci-queue-controller.service`; an abnormal launcher exit
must trigger the independent host alert service and no blind retry occurs.

Long-lived CI controller material is canonical in Proton Pass before it is
installed at its narrow runtime boundary:

The provider setup itself is pinned in
[`deploy/github-app-contracts.json`](deploy/github-app-contracts.json). Create
the organization-owned Apps with the exact display names
`Makepad PostgreSQL CI Checks` and `Makepad PostgreSQL CI Launcher`, disable
and empty both webhooks, subscribe to no events, and install each using
selected-repository access to `Makepad-fr/postgres` only. The public repository
runner groups continue to allow public repositories, but remain selected to
this one exact repository and protected workflow set.

| Proton Pass item | Exact runtime fields and authority |
| --- | --- |
| `PostgreSQL · PR Checks App` | repository variable `POSTGRES_PR_CHECK_APP_ID` and protected `postgres-ci-attestation` secret `POSTGRES_PR_CHECK_APP_PRIVATE_KEY`; App installed only on this repository with Metadata read, Checks write, and organization self-hosted-runners read; it has no Actions permission |
| `PostgreSQL · JIT Launcher App` | root-only hypervisor `POSTGRES_CI_LAUNCHER_APP_ID`, `POSTGRES_CI_LAUNCHER_APP_INSTALLATION_ID`, and mode-0400 `POSTGRES_CI_LAUNCHER_APP_PRIVATE_KEY_FILE`; repository variable `POSTGRES_CI_LAUNCHER_APP_SENDER_ID`; App installed only on this repository with Metadata read, Actions read, Contents write for repository dispatch, Issues write for secondary alerts, Pull requests read, and organization self-hosted-runners write |
| `PostgreSQL · JIT hypervisor attestation` | root-only mode-0400 `POSTGRES_CI_ATTESTATION_PRIVATE_KEY_FILE`; repository variable `POSTGRES_CI_ATTESTATION_PUBLIC_KEY`; reviewed repository variable and root-only value `POSTGRES_CI_APPROVED_BASE_IMAGE_SHA256`/`POSTGRES_CI_BASE_IMAGE_SHA256` |
| `PostgreSQL · runner-group controller` | administrator workstation input streamed to `scripts/configure-postgres-ci-runner-group.sh`; organization runner-group write and repository Metadata read only, never installed on a runner or hypervisor |
| `PostgreSQL · CI hypervisor alert` | root-only host alert URL file consumed only by the systemd `OnFailure` handler; never mirrored to GitHub Actions |
| `PostgreSQL · GitHub repository variable bootstrap` | one-time operator credential used only by `--sync-repository-variables`; exact repository Variables write and Metadata read, with no Actions, Contents, Administration, Environments, Secrets, or organization permission |

The Launcher and Checks Apps are different installations and keys. Store their
numeric IDs, installation IDs, public-key fingerprints, approved base-image
digest, and rotation history beside the Proton items so reconciliation can
compare identities without printing secrets. The hypervisor's immutable base
image is root-owned, non-writable, has no backing/data chain, and is verified by
the reviewed SHA-256 both before and after each full per-job copy.

## Keycloak 26.7.3 cohort restore evidence

Before the six-realm Keycloak release, dispatch protected workflow `Verify
Keycloak Cohort Restore Compatibility` with the exact lowercase current
Keycloak protected-main SHA. There is no mutable rollout repository variable.
The workflow resolves `Makepad-fr/keycloak` main independently, checks out that
exact release, and verifies its pinned
`dhi.io/keycloak:26-debian13@sha256:fab1484b1762fd1269e63a40f068ec73ea75b498eaaa5d02f62f022a5d00ff0f`
runtime and upstream version `26.7.3`.

The protected release runner captures fresh custom-format, no-owner,
no-privilege dumps of exactly `keycloak_betacrew`, `keycloak_catwlk`,
`keycloak_makepad`, `keycloak_runtrace`, `keycloak_vestiaire`, and
`keycloak_vif` from the exact healthy production Compose container. Every dump
is structurally inspected. Each is then restored into a fresh internal Docker
network and disposable PostgreSQL instance. Catwlk uses the custom DHI-derived
provider image built from the exact checked-out Keycloak release; the other five
instances use the pinned base image. Each runtime must become ready and the v2
secret-safe fingerprints for realm settings/themes/SMTP, authentication flows,
roles/composites, clients/scopes/mappers, identity providers, components, and
required actions must remain stable. Canonical sorted rows are streamed directly
into SHA-256; raw configuration values are never written or logged. The check
fails when a required persistence table disappears. Because Keycloak's schema is
internal, a reviewed schema change requires coordinated fingerprint/evidence
schema revisions rather than a silent fallback.
No dump is uploaded as an Actions artifact, and remote and local copies are
deleted in the always-cleanup step.

Success uploads exactly one artifact named
`keycloak-cohort-restore-evidence-<run>-<attempt>` containing only canonical
`keycloak-cohort-restore-evidence.json`, schema
`makepad.keycloak-cohort-restore-evidence.v2`. It binds the exact PostgreSQL
workflow/run/attempt/main SHA, exact Keycloak release SHA/base image/version,
the immutable locally built Catwlk image ID, fingerprint schema, and the sorted
six-instance list. Each entry contains its slug, database, fresh backup SHA-256,
exact runtime identity, category and combined hashes, and `passed` restore,
Keycloak-startup, and configuration-regression statuses. The Keycloak deployment
consumer must resolve that exact completed
successful main-branch workflow run and artifact; operator assertions are not
evidence.

The `keycloak-cohort-restore` environment is protected to `main` with required
reviewers. Provision its long-lived fields in Proton Pass first, then mirror
only to that environment:

| Proton Pass item | Protected environment fields |
| --- | --- |
| `PostgreSQL · Keycloak cohort source reader` | `KEYCLOAK_COHORT_SOURCE_TOKEN`, dedicated token/App broker restricted to `Makepad-fr/keycloak` with Metadata and Contents read only |
| `Hetzner Database Server makepad` | canonical `DEPLOY_SSH_*` fields mirrored to `KEYCLOAK_COHORT_DB_SSH_PRIVATE_KEY`, `KEYCLOAK_COHORT_DB_SSH_KNOWN_HOSTS`, `KEYCLOAK_COHORT_DB_SSH_HOST`, `KEYCLOAK_COHORT_DB_SSH_PORT`, and `KEYCLOAK_COHORT_DB_SSH_USER`; dedicated non-root Docker-capable DB capture account only |
| `Makepad Docker Hardened Images` | canonical `DOCKERHUB_USERNAME` and `DOCKERHUB_PRO_PAT` fields mirrored to `DHI_REGISTRY_USERNAME` and `DHI_REGISTRY_PASSWORD`, with read-only pull access to the exact reviewed Keycloak image |

The source token has no Actions write, Checks, Administration, Environments,
Secrets, Deployments, or organization permissions. The DB capture account has
no interactive command. Before adding its GitHub secret, an operator runs
`scripts/install-keycloak-cohort-capture-host.sh <capture-user>
<authorized-public-key-file>` as root on the database host. The installer writes
a root-owned `authorized_keys` forced command, disables forwarding and TTYs,
validates sshd, installs the reviewed capture helper, and enables the persistent
cohort cleanup timer. The workflow first proves the installed helper and
cleaner's exact SHA-256 digests, active timer, and successful last cleaner result,
then may issue only validated
`probe`/`capture`/`fetch`/`cleanup` commands. Checked-out code is never copied to
or executed on the database host.

Run `scripts/install-keycloak-cohort-cleaner.sh` as root on the protected release
runner host as well. The persistent timer removes expired exactly labeled cohort
containers and networks plus `/tmp/postgres-keycloak-cohort-*` directories after
three hours, including after host downtime. Disposable database and Keycloak
passwords are mode-0400 mounted files rather than Docker configuration
environment values. The ordinary `always()` step still removes local and remote
material immediately after a run.

Production additionally requires:

- `DEPLOY_VIF_DB_NETWORK`
- `DEPLOY_VIF_DB_PASSWORD`

Production can override the VIF database and role names with `DEPLOY_VIF_DB_NAME` and `DEPLOY_VIF_DB_USER`; both default to `vif`.
The VIF password is written only to a mode-0600 file inside a mode-0700,
job-scoped runtime directory. It is never persisted in `.env.deploy` or passed
through a `psql -v` argument; the mounted bootstrap reads it with `\getenv`.

`DEPLOY_SSH_USER` must be a non-root deployment account with the Docker permissions needed to create overlay networks and deploy the stack. The workflow rejects `DEPLOY_SSH_USER=root`.

Before an ordinary non-Brio deployment, provision the PostgreSQL superuser
password as a non-empty root-owned mode-0600 file on the database node. The
production default is `/etc/makepad/secrets/postgres-superuser-password`.
Canary's `/etc/makepad/secrets/postgres-canary-superuser-password` is instead
provisioned by its protected workflow environment. PostgreSQL receives the
value through `POSTGRES_PASSWORD_FILE`; helpers mount it read-only instead of
placing it in command arguments or tracked environment files.

Provision a private-CA-issued PostgreSQL server certificate before deployment.
Its SANs must include every hostname clients verify, including
`makepad-postgres`, `makepad-postgres-brio-staging`, and the DB VM hostname used
by Keycloak. Keep the unencrypted private key outside git. Canary automatically
creates and content-labels its required `v2` Swarm objects from protected
environment secrets, or rejects an existing name whose label/content differs.
The following commands describe the equivalent recovery operation and the
production object:

```sh
docker config create makepad_postgres_tls_cert_v1 /secure/path/server.crt
docker secret create makepad_postgres_tls_key_v1 /secure/path/server.key
docker config create makepad_postgres_canary_tls_cert_v2 /secure/path/canary-server.crt
docker secret create makepad_postgres_canary_tls_key_v2 /secure/path/canary-server.key
```

The names must match `MAKEPAD_POSTGRES_TLS_CERT_CONFIG` and `MAKEPAD_POSTGRES_TLS_KEY_SECRET` in the selected `.env.db`. Rotate by creating new versioned objects, updating those two names, and redeploying; never replace private-key material in place. Distribute only the issuing CA certificate to Runtrace, Brio, and Keycloak hosts. The deployment creates the versioned `MAKEPAD_POSTGRES_RUNTRACE_HBA_CONFIG` from the committed policy when absent and rejects content drift under an existing name. The policy preserves the source-restricted Fresko and BetaCrew rules described above, rejects plaintext connections to `runtrace`, `keycloak_runtrace`, `brio_staging`, and `keycloak_brio_staging`, and requires SCRAM authentication over TLS for those databases. Each Brio application and backup role is also rejected from every database except its named target; unrelated shared databases retain their current SCRAM transport policy during migration.
The Brio HBA policy uses fresh immutable `makepad_postgres_canary_runtrace_hba_v3`
and `makepad_postgres_runtrace_hba_v3` object names; deployed `v2` objects are
historical and must never be replaced or relabelled in place.

The workflow copies checked-in deployment entrypoints and deploys only the
PostgreSQL stack. Canary first validates the password and CA files, certificate
chain, certificate/key match, seven-day expiry margin, and exact
`makepad-postgres-brio-staging` SAN. A mismatch fails before stack deployment.
If a configured database network is absent it is created as an encrypted
overlay; existing network drift fails closed. After exact-image convergence,
the canary entrypoint runs the idempotent app bootstrap, proves the alias and
`sslmode=verify-full` connection, proves plaintext and cross-database access are
rejected, proves the backup role is read-only, then requires a new checksummed
CMS-encrypted backup before the workflow succeeds.

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
- The standalone DB-VM `keycloak_brio_staging_backup` dumps only
  `keycloak_brio_staging` as the read-only
  `keycloak_brio_staging_backup` role and uses the certificate-SAN hostname
  configured in `MAKEPAD_POSTGRES_BRIO_IDENTITY_BACKUP_DB_HOST`. There is no
  Swarm form of this identity backup service.

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

The canary Swarm and standalone DB-VM deploy preflights copy the tracked backup
scripts, reject symlinked inputs, require each backup directory to be owned by
uid 999 with mode 0700, require each database credential to be owned by uid 999
with mode 0400, and require a root-owned, non-writable public recipient
certificate that remains valid for at least seven days and can create a CMS
AES-256-GCM envelope.
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

Brio release evidence observes the shared database runtime without receiving a
database or deployment credential. After deriving the public half of Brio's
dedicated release-observer SSH key from its canonical Proton Pass item, install
the bounded host observer once as root:

```sh
scripts/install-brio-runtime-observer.sh \
  scripts/brio-runtime-observe.sh \
  scripts/brio-postgres-control-receipt.py \
  /secure/operator-path/brio-release-observer.pub
```

The installer creates a locked `brio-runtime-observer` account whose key is
bound with OpenSSH `restrict` to one root-owned command. The command accepts
only `shared-runtime-observe`; it verifies the exact healthy standalone
`postgres/postgres` Compose unit, binds the running image content to its
immutable reference, and returns bounded image, version, and lifecycle JSON.
The root-owned helper opens a fixed read-only local `psql` transaction against
PostgreSQL's system settings and `pg_hba_file_rules`; it never selects an
application table or accepts a caller-selected SQL statement. It requires live
TLS, SCRAM password encryption, the exact ordered Brio application/identity and
backup HBA allows/rejects, and zero HBA parse errors. Credential-free local
`psql` probes must be rejected by the two leading `hostnossl` rules before
authentication. A PostgreSQL SSLRequest then upgrades a connection to
`127.0.0.1` twice and verifies the same live server certificate against the
root-owned CA for both the Brio application alias
`makepad-postgres-brio-staging` and the reviewed identity-host IP. The emitted
`makepad.brio.runtime-controls.v1` receipt contains only normalized settings,
HBA identities, host-network/listener identity, per-path TLS protocols, explicit
verify-full results, and the shared server-certificate SHA-256 fingerprint. It
does not copy the certificate's raw SAN list and never contains a password,
connection credential, database row, private key, or probe error body. The SSH
boundary cannot inspect container environment or mounts, run arbitrary Docker
commands, or mutate the host. Never install a deployment key for this account
or mirror the observer private key to this repository.

If production overrides `DEPLOY_VIF_DB_NAME` or `DEPLOY_VIF_DB_USER`, use those values in the connection URI.

## Validation

Run the static deployment checks and the disposable PostgreSQL 16 bootstrap test:

```sh
./scripts/validate-postgres-config.sh
./scripts/test-brio-bootstrap.sh
./scripts/test-brio-encrypted-backup.sh
./scripts/test-brio-encrypted-restore.sh
./scripts/test-brio-deploy-guards.sh
./scripts/test-brio-deployment-contracts.sh
./scripts/test-brio-deployment-failures.sh
./scripts/test-brio-runtime-observer.sh
```

Run the local static checks before opening a deployment PR:

```bash
bash scripts/validate-postgres-config.sh
bash scripts/test-runtrace-tls-policy.sh
bash scripts/test-runtrace-backup.sh
bash scripts/test-brio-encrypted-backup.sh
bash scripts/test-brio-encrypted-restore.sh
bash scripts/test-brio-deploy-guards.sh
bash scripts/test-brio-deployment-contracts.sh
bash scripts/test-brio-deployment-failures.sh
bash scripts/test-brio-runtime-observer.sh
```
