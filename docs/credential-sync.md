# PostgreSQL Proton-to-GitHub credential sync

`deploy/credential-inventory.json` maps the shared Proton Pass vault `Makepad`
to the five existing GitHub Environments used by the reviewed PostgreSQL
release path:

- `canary`
- `production`
- `staging-brio-identity-db`
- `release-brio-identity-db`
- `keycloak-cohort-restore`

The inventory contains names and immutable provider identities, never values.
It also records existing shared-environment names that this helper must preserve
without reading, changing, or deleting them. Its `operatorEntries` list is
empty: it grants no authority over runners, GitHub Apps, OAuth Apps, repository
values, host files, branch protection, or environment configuration.

## Read-only audit

Run the name-and-policy audit first:

```sh
./scripts/sync-github-environments.sh --check
./scripts/sync-github-environments.sh --check --environment staging-brio-identity-db
```

Check mode pins the public repository identity, native `policy-and-integration`
required check, protected-main settings, read-only Actions token policy, exact
environment IDs, reviewer boundary, and exact `main` deployment branch-policy
IDs. It reads active Proton item titles and GitHub destination names only. It
does not call `pass-cli item view` or perform a provider write.

A missing required source or destination returns status 1. An unmanaged GitHub
destination returns status 2. Preserved names are reported separately and do
not enter the helper's write set.

## Explicit one-environment sync

After reviewing the read-only result and receiving action-time approval, sync
one existing environment with its exact confirmation string:

```sh
./scripts/sync-github-environments.sh --sync \
  --environment staging-brio-identity-db \
  --confirm Makepad-fr/postgres:staging-brio-identity-db
```

Replace the environment in both places with one of the other four reviewed
names when that exact scope is approved. There is no all-environment write
mode.

Before the first write the helper:

1. rejects repository, main-policy, environment, reviewer, or branch-policy
   identity drift;
2. rejects repository-level or unmanaged environment destinations;
3. reads and bounds every selected Proton field in memory;
4. repeats all provider policy/name checks; and
5. rereads every source field to detect rotation during preflight.

Values are streamed to `gh` over standard input. They are not placed in
arguments, exported child environments, logs, or workspace files. Public
environment variables receive exact-value readback. GitHub does not expose
secret values, so secrets receive name/metadata readback. The helper repeats
source and destination checks before reporting `SYNC_COMPLETE`.

The operation is idempotent. A failed partial sync can be inspected and rerun
because each write sets the same reviewed destination. The helper cannot create
or delete an environment, modify Proton Pass, alter a provider policy, delete a
legacy name, or write repository-level values.

## Reviewed source records

- `Hetzner App Server makepad` supplies the native SSH fields for the existing
  shared canary and production workflows.
- `Hetzner Database Server makepad` supplies the five standalone database-host
  SSH fields for Brio identity deployment only.
- `PostgreSQL · Keycloak cohort capture SSH` supplies the five dedicated,
  forced-command SSH fields for cohort restore only.
- `PostgreSQL · canary Swarm deployment` supplies canary-only deployment
  paths, stack name, and isolated encrypted transport networks. Brio staging
  uses `makepad_brio_staging_db_control` and `makepad_brio_staging_db_aux`
  for the two base Compose networks, plus its internal application database
  network. These settings do not reuse other applications' canary networks.
- `PostgreSQL · shared Swarm deployment` and
  `Le Petit Coin GitHub Deploy Secrets` supply existing shared deployment
  constants.
- `Brio Staging - PostgreSQL` supplies Brio role passwords and canary inputs.
- `Brio Staging - PKI and Backup Keys` supplies certificate, recovery, hostname,
  and source-CIDR inputs.
- `PostgreSQL · Brio identity release orchestrator` supplies the dedicated
  Keycloak release-dispatch token.
- `PostgreSQL · Keycloak cohort source reader` supplies the read-only source
  token used by restore evidence.
- `Makepad Docker Hardened Images` supplies the cohort verifier pull identity.

The JSON inventory is authoritative for every destination-to-field mapping.
Changing a workflow credential requires a reviewed inventory and adversarial
test update in the same PR.

## Validation

```sh
bash scripts/test-sync-github-environments.sh
```

The test uses isolated fake providers to prove check-mode non-disclosure, exact
write confirmation, preflight-before-write behavior, source and provider drift
rejection, no value output, variable readback, preserved-name isolation, and
the absence of runner/App authority.
