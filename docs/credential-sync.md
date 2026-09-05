# PostgreSQL credential inventory and GitHub sync

`deploy/credential-inventory.json` is the reviewed mapping from the shared
Proton Pass vault `Makepad` to `Makepad-fr/postgres`. It covers the six
protected GitHub environments, the four public repository policy variables,
and the root/operator boundaries used by the disposable-runner control plane.
Repository code never creates, rotates, or deletes a credential.

Three existing names in `staging-brio-identity-db` are separately inventoried
as name-only retained destinations: two secrets and one variable. They have no
Proton source and no sync write path:

- `BRIO_STAGING_DB_PASSWORD`
- `BRIO_STAGING_BACKUP_DB_PASSWORD`
- `POSTGRES_HOST_COMPOSE_PROJECT`

The two Brio application-password names remain active inputs in `canary`, but
their copies in the identity environment have no consumer: that workflow uses
only the Keycloak database roles. `POSTGRES_HOST_COMPOSE_PROJECT` is an
obsolete selector because the standalone deployment pins Compose project
`postgres` in code. The helper reports whether each exact retained name is
present, but never reads, writes, or deletes it. Keep the provider values until
an explicit, separately reviewed cleanup is authorized; any other unlisted
name remains a fail-closed error.

`deploy/github-app-contracts.json` separately pins both organization-owned App
names, owner, exact selected-repository installation, disabled and empty
webhooks, empty event subscriptions, and least-privilege permission maps. It
also pins the canonical repository-variable bootstrap item and its exact
Variables-write/Metadata-read scope. `scripts/validate-github-provider-contract.py`
rejects any drift before credential synchronization reaches a provider call.

`scripts/validate-credential-inventory-contract.py` independently pins every
environment/kind/destination/Proton-item/field tuple, plus every repository and
non-GitHub tuple. Both check and sync modes run it before the first provider
call, so a plausible-looking source substitution or reclassification fails
closed rather than becoming a new implicit credential route.

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

Reconcile the four public repository trust anchors as one separately bounded
operation:

```sh
./scripts/sync-github-environments.sh --sync-repository-variables \
  --confirm Makepad-fr/postgres:repository-variables
```

That operation reads its process-local GitHub credential only from Proton item
`PostgreSQL · GitHub repository variable bootstrap`, field
`repository_variable_admin_token`; it never uses the ambient `gh` session for
repository-variable writes or exact-value read-back. Record `owner` and
`expires_at` on the same item and revoke the credential after reconciliation.

Sync mode rejects an omitted or arbitrary environment. Before its first field
read it proves this intentionally public repository is active and uses `main`
as its default branch; proves the selected environment has exactly one custom
branch policy named and typed `main` and the exact reviewed reviewer, timer,
and self-review policy; rejects every repository-level secret;
and rejects unlisted environment or repository names. Public forks are treated
as untrusted: protected workflow and disposable-runner controls remain the
execution boundary. The helper then reads every selected Proton field before
the first GitHub write, rechecks provider names and policy, and streams each
value to `gh secret set` or `gh variable set` over standard input. Values exist
briefly only in process memory: tracing/debug output and core dumps are
disabled, and values never enter arguments, exported child environments, logs,
or files.

The helper never creates an environment, changes a branch policy, modifies
Proton Pass, or deletes a GitHub name. Its ordinary `--sync --environment`
mode never sets repository-level values. The explicit repository-variable mode
reads all four reviewed fields before its first write, validates GitHub IDs as
canonical positive decimals, the base-image digest as lowercase SHA-256, and
the attestation key as canonical Ed25519 SubjectPublicKeyInfo PEM. It streams
each value to GitHub over standard input and compares two provider read-backs
byte-for-byte with the in-memory Proton value. A legacy
name must be removed manually only after its consumer has migrated and the
approved replacement has been read back. The three exact name-only retained
destinations are the bounded exception described above; they are reported but
excluded from both the managed-write set and the unexpected-name count. Exit
`0` means the reviewed names and
protection are complete, exit `1` means a required source/destination or policy
is incomplete, and exit `2` means an unlisted GitHub name remains.

## Protected environment mirrors

Every arrow below means `Proton item/field -> GitHub destination`. Fields
consumed as `secrets.*` stay environment secrets; non-confidential hostnames
and CIDRs consumed as `vars.*` are environment variables.

### `canary`

- `Hetzner App Server makepad` fields `host`, `port`, `user`, `private_key`,
  and `known_hosts` map to the five exact `DEPLOY_SSH_*` secrets.
- `PostgreSQL · shared Swarm deployment` maps the PostgreSQL remote directory,
  stack, and Catwlk network used by the canary workflow.
- `Le Petit Coin GitHub Deploy Secrets/DEPLOY_DB_NETWORK` maps to
  `DEPLOY_LE_PETIT_COIN_DB_NETWORK`, so PostgreSQL joins the exact application-
  owned database overlay rather than relying on a duplicated network name.
- `Brio Staging - PostgreSQL` maps `DEPLOY_BRIO_STAGING_DB_NETWORK`,
  `POSTGRES_CANARY_SUPERUSER_PASSWORD`, `BRIO_STAGING_DB_PASSWORD`, and
  `BRIO_STAGING_BACKUP_DB_PASSWORD`.
- `Brio Staging - PKI and Backup Keys` maps `POSTGRES_CA_PEM`,
  `POSTGRES_SERVER_CERT_PEM`, `POSTGRES_SERVER_KEY_PEM`, and
  `BRIO_BACKUP_RECIPIENT_CERT_PEM`.

The two Keycloak database passwords are not canary inputs. If old copies remain
there, the helper reports them as unmanaged instead of silently retaining or
deleting them.

### `production`

- The same five native `Hetzner App Server makepad` fields map to the exact
  `DEPLOY_SSH_*` secrets.
- `PostgreSQL · shared Swarm deployment` maps the PostgreSQL remote directory,
  stack, Catwlk/VIF networks, VIF database and role names, and the VIF password
  consumed by the workflow.
- `Le Petit Coin GitHub Deploy Secrets/DEPLOY_DB_NETWORK` maps to the
  `DEPLOY_LE_PETIT_COIN_DB_NETWORK` workflow alias.

Historical Fashion or Scraping fields are not consumed by the current
workflow and are deliberately absent from the reviewed inventory.

### `staging-brio-identity-db`

- `Hetzner Database Server makepad` supplies canonical custom fields
  `DEPLOY_SSH_HOST`, `DEPLOY_SSH_PORT`, `DEPLOY_SSH_USER`,
  `DEPLOY_SSH_PRIVATE_KEY`, and `DEPLOY_SSH_KNOWN_HOSTS`, which map to their
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

Existing identity-environment copies of `BRIO_STAGING_DB_PASSWORD` and
`BRIO_STAGING_BACKUP_DB_PASSWORD` are retained name-only: their real managed
destinations remain in `canary`, where `manual-deploy.yml` consumes them.
`POSTGRES_HOST_COMPOSE_PROJECT` is likewise retained name-only while cleanup is
pending; `deploy-brio-identity-db-host.sh` fixes the Compose project to
`postgres` and accepts no workflow-controlled selector. These entries are not
permission to recreate a missing name.

### Release, cohort restore, and CI attestation

- `release-brio-identity-db` receives only the dedicated
  `KEYCLOAK_RELEASE_ORCHESTRATOR_TOKEN` secret.
- `keycloak-cohort-restore` receives its read-only Keycloak source token, the
  five DB-capture SSH aliases from `Hetzner Database Server makepad`, and the
  DHI pull username/token.
- `postgres-ci-attestation` receives only the Checks App private key. The
  Launcher App private key and the Ed25519 signing key never enter Actions.
  This machine-only result publisher is the deliberate reviewer exception: it
  has no required reviewer, no self-review setting, and no wait timer so a
  signed CI result cannot deadlock behind a human approval.

All other inventory environments require the pinned `idilsaglam` GitHub user
(immutable ID `39597780`), `prevent_self_review=true`, and a zero-minute wait
timer. The policy reconciler validates that live reviewer identity before and
after a write and compares the complete provider read-back with this matrix.

## Public repository variables and forbidden repository secrets

The job-level dispatch guard must read
`POSTGRES_CI_LAUNCHER_APP_SENDER_ID` before GitHub exposes an environment, so
that immutable bot ID is a repository variable. The related
`POSTGRES_PR_CHECK_APP_ID`, `POSTGRES_CI_ATTESTATION_PUBLIC_KEY`, and
`POSTGRES_CI_APPROVED_BASE_IMAGE_SHA256` are also public policy inputs and
remain repository variables. They are identifiers, a public key, and a digest,
not credentials. Check mode audits their exact names and canonical Proton item
titles without reading values. Only the explicitly confirmed
`--sync-repository-variables` operation may overwrite them, and success requires
semantic validation plus exact value read-back for all four anchors.

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
