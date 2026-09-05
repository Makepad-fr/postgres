# PostgreSQL credential inventory and GitHub sync

`deploy/credential-inventory.json` is the reviewed mapping from the shared
Proton Pass vault `Makepad` to `Makepad-fr/postgres`. It covers the six
protected GitHub environments, the four public repository policy variables,
and the root/operator boundaries used by the disposable-runner control plane.
Repository code never creates, rotates, or deletes a credential.

Run the non-mutating audit first:

```sh
./scripts/sync-github-environments.sh --check
./scripts/sync-github-environments.sh --check --environment canary
```

Check mode reads active Proton item **titles only** with `pass-cli item list`.
It never calls `pass-cli item view`, so it never materializes a credential
field. From GitHub it reads only repository metadata, environment protection,
and secret/variable names. A whole-inventory check lists the root/operator
destinations as `operator-managed`; it does not inspect those systems.

After resolving every reported missing or unmanaged name, sync exactly one
environment:

```sh
./scripts/sync-github-environments.sh --sync --environment canary
./scripts/sync-github-environments.sh --sync --environment production
./scripts/sync-github-environments.sh --sync --environment staging-brio-identity-db
./scripts/sync-github-environments.sh --sync --environment release-brio-identity-db
./scripts/sync-github-environments.sh --sync --environment keycloak-cohort-restore
./scripts/sync-github-environments.sh --sync --environment postgres-ci-attestation
```

Sync mode rejects an omitted or arbitrary environment. Before its first field
read it proves this intentionally public repository is active and uses `main`
as its default branch; proves the selected environment has exactly one custom
branch policy named and typed `main`; rejects every repository-level secret;
and rejects unlisted environment or repository names. Public forks are treated
as untrusted: protected workflow and disposable-runner controls remain the
execution boundary. The helper then reads every selected Proton field before
the first GitHub write, rechecks provider names and policy, and streams each
value to `gh secret set` or `gh variable set` over standard input. Values exist
briefly only in process memory: tracing/debug output and core dumps are
disabled, and values never enter arguments, exported child environments, logs,
or files.

The helper never creates an environment, changes a branch policy, modifies
Proton Pass, sets repository-level values, or deletes a GitHub name. A legacy
name must be removed manually only after its consumer has migrated and the
approved replacement has been read back. Exit `0` means the reviewed names and
protection are complete, exit `1` means a required source/destination or policy
is incomplete, and exit `2` means an unlisted GitHub name remains.

## Protected environment mirrors

Every arrow below means `Proton item/field -> GitHub destination`. Fields
consumed as `secrets.*` stay environment secrets; non-confidential hostnames
and CIDRs consumed as `vars.*` are environment variables.

### `canary`

- `Hetzner Database Server makepad/DEPLOY_SSH_*` maps to the five exact
  `DEPLOY_SSH_*` secrets.
- `PostgreSQL · shared Swarm deployment` maps the remote directory, stack, and
  three network fields used by the canary workflow.
- `Brio Staging - PostgreSQL` maps only
  `POSTGRES_CANARY_SUPERUSER_PASSWORD`, `BRIO_STAGING_DB_PASSWORD`, and
  `BRIO_STAGING_BACKUP_DB_PASSWORD`.
- `Brio Staging - PKI and Backup Keys` maps `POSTGRES_CA_PEM`,
  `POSTGRES_SERVER_CERT_PEM`, `POSTGRES_SERVER_KEY_PEM`, and
  `BRIO_BACKUP_RECIPIENT_CERT_PEM`.

The two Keycloak database passwords are not canary inputs. If old copies remain
there, the helper reports them as unmanaged instead of silently retaining or
deleting them.

### `production`

- `Hetzner Database Server makepad/DEPLOY_SSH_*` maps to the five exact SSH
  secrets.
- `PostgreSQL · shared Swarm deployment` maps the remote directory, stack,
  Catwlk/Le Petit Coin/VIF networks, VIF database and role names, and the VIF
  password consumed by the workflow.

Historical Fashion or Scraping fields are not consumed by the current
workflow and are deliberately absent from the reviewed inventory.

### `staging-brio-identity-db`

- The five canonical `DEPLOY_SSH_*` fields map to their
  `BRIO_IDENTITY_DB_DEPLOY_SSH_*` aliases.
- `Brio Staging - PostgreSQL` maps only the Keycloak application and backup
  database passwords.
- `Brio Staging - PKI and Backup Keys` maps the public recovery recipient
  certificate as an environment secret, matching the workflow, plus
  `BRIO_IDENTITY_DB_HOSTNAME` and `BRIO_KEYCLOAK_DB_SOURCE_CIDR` as variables.

The CA, PostgreSQL server certificate, and PostgreSQL private key are used only
by `canary`; they must never be copied into this DB-host deployment environment.
The recovery recipient certificate is needed by both workflows and is the only
PKI/backup-certificate field mirrored here.

### Release, cohort restore, and CI attestation

- `release-brio-identity-db` receives only the dedicated
  `KEYCLOAK_RELEASE_ORCHESTRATOR_TOKEN` secret.
- `keycloak-cohort-restore` receives its read-only Keycloak source token, the
  five DB-capture SSH aliases, and the DHI pull username/token.
- `postgres-ci-attestation` receives only the Checks App private key. The
  Launcher App private key and the Ed25519 signing key never enter Actions.

## Public repository variables and forbidden repository secrets

The job-level dispatch guard must read
`POSTGRES_CI_LAUNCHER_APP_SENDER_ID` before GitHub exposes an environment, so
that immutable bot ID is a repository variable. The related
`POSTGRES_PR_CHECK_APP_ID`, `POSTGRES_CI_ATTESTATION_PUBLIC_KEY`, and
`POSTGRES_CI_APPROVED_BASE_IMAGE_SHA256` are also public policy inputs and
remain repository variables. They are identifiers, a public key, and a digest,
not credentials. The generic helper audits their exact names and canonical
Proton item titles but does not overwrite repository variables.

Repository-level secrets are forbidden. Their exposure boundary would include
workflows that have not passed a protected environment gate. Any repository
secret name blocks both check and sync; the helper never reads or deletes it.

## Proton-only and root-only destinations

The inventory records these separately so they cannot be confused with an
Actions mirror:

- Launcher App ID and installation ID are root-only `controller.env` settings;
  its private key is `/etc/makepad/postgres-ci/launcher-app-private-key.pem`
  mode `0400`. GitHub receives only the bot user ID as a public variable.
- The Ed25519 private key is
  `/etc/makepad/postgres-ci/attestation-private-key.pem` mode `0400`. GitHub
  receives only its public key. The reviewed qcow2 digest is present both in
  root-only controller configuration and as a public policy variable.
- The repository numeric ID is root-only controller configuration.
- The runner-group administration token is streamed only to
  `scripts/configure-postgres-ci-runner-group.sh` on an administrator
  workstation; it is never installed on a runner or hypervisor.
- The host alert URL remains a root-only file consumed by the systemd failure
  handler and is never mirrored to Actions.

Install a private key from `pass-cli` directly into a newly created owner-only
file using a trusted root process. Do not use a command-line argument, dotenv
file, runner workspace, shell history, clipboard, or GitHub secret as an
intermediate. Compare the non-secret fingerprint recorded in Proton after
installation.

Ephemeral `GITHUB_TOKEN`, GitHub App installation tokens, runner registration
tokens, and disposable database passwords are intentionally absent: they are
minted per operation and never retained.
