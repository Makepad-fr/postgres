# Makepad Postgres

Shared PostgreSQL deployment for Makepad-fr applications.

This repository owns the shared PostgreSQL server. Application repositories connect either through the shared overlay network alias or through the configured DB VM host endpoint, depending on their deployment topology. Application repositories should not deploy PostgreSQL directly in canary or production.

## Layout

- `compose.yml`: base PostgreSQL service definition
- `envs/canary/compose.yml`: canary Swarm overrides
- `envs/canary/.env.db`: canary PostgreSQL settings
- `envs/production/compose.yml`: production Swarm overrides
- `envs/production/.env.db`: production PostgreSQL settings
- `bootstrap/keycloak-new-instances.sql`: idempotent SQL bootstrap for the Vif, Makepad, and Vestiaire Keycloak databases

## Networks

The database joins external overlay networks configured through Compose:

- `${MAKEPAD_POSTGRES_DB_NETWORK}`
- `${MAKEPAD_POSTGRES_LE_PETIT_COIN_DB_NETWORK}`

The manual deploy workflow sources these Compose variables from environment secrets:

- `DEPLOY_CATWLK_DB_NETWORK`
- `DEPLOY_LE_PETIT_COIN_DB_NETWORK`

Application network topology is owned by the consuming application repositories. New Keycloak instances keep their own DB-facing Docker networks in the Keycloak repository and connect to this PostgreSQL server through the configured DB endpoint.

When using this repository's overlay-network deployment model, application stacks attached to the shared database network should use the stable service alias `makepad-postgres`. Le Petit Coin stacks attach through their app-specific database network and should use `makepad-postgres-le-petit-coin`. The current production Keycloak deployment is separate from this stack and uses the DB VM host address instead; that host-based path depends on the standalone DB VM deployment exposing PostgreSQL on the VM host.

## Node Labels

Pin the shared PostgreSQL server to the dedicated database node:

```bash
docker node update --label-add infra.makepad.postgres=true <db-node>
```

## Deployment

Use the manual GitHub Actions workflow in this repository.

Required environment secrets:

- `DEPLOY_SSH_HOST`
- `DEPLOY_SSH_PORT`
- `DEPLOY_SSH_USER`
- `DEPLOY_SSH_PRIVATE_KEY`
- `DEPLOY_REMOTE_DIR`
- `DEPLOY_STACK_NAME`
- `DEPLOY_CATWLK_DB_NETWORK`
- `DEPLOY_LE_PETIT_COIN_DB_NETWORK`

The workflow deploys only the PostgreSQL stack. If one of the configured database networks does not exist yet, it is created on the manager before deployment.

## Application Databases

Create one database and one dedicated user per application.

Vif, Makepad, and Vestiaire use these databases and roles:

| Application | Database | Role |
| --- | --- | --- |
| Vif | `keycloak_vif` | `keycloak_vif_app` |
| Makepad | `keycloak_makepad` | `keycloak_makepad_app` |
| Vestiaire | `keycloak_vestiaire` | `keycloak_vestiaire_app` |

Run the idempotent bootstrap with generated passwords. `POSTGRES_ADMIN_URL` must be a PostgreSQL superuser connection URI for the target server, usually using the `postgres` role, because the bootstrap creates roles, sets passwords, creates databases, and assigns database ownership. For example: `postgres://postgres@<db-vm-host>:5432/postgres?sslmode=disable`.

```bash
: "${POSTGRES_ADMIN_URL:?set POSTGRES_ADMIN_URL to a PostgreSQL superuser connection URI}"
: "${KEYCLOAK_VIF_DB_PASSWORD:?set KEYCLOAK_VIF_DB_PASSWORD to a generated password}"
: "${KEYCLOAK_MAKEPAD_DB_PASSWORD:?set KEYCLOAK_MAKEPAD_DB_PASSWORD to a generated password}"
: "${KEYCLOAK_VESTIAIRE_DB_PASSWORD:?set KEYCLOAK_VESTIAIRE_DB_PASSWORD to a generated password}"

psql "$POSTGRES_ADMIN_URL" \
  -v keycloak_vif_app_password="$KEYCLOAK_VIF_DB_PASSWORD" \
  -v keycloak_makepad_app_password="$KEYCLOAK_MAKEPAD_DB_PASSWORD" \
  -v keycloak_vestiaire_app_password="$KEYCLOAK_VESTIAIRE_DB_PASSWORD" \
  -f bootstrap/keycloak-new-instances.sql
```

The current production Keycloak environments connect with the DB VM host:

```text
postgres://keycloak_vif_app:<secret>@<db-vm-host>:5432/keycloak_vif?sslmode=disable
postgres://keycloak_makepad_app:<secret>@<db-vm-host>:5432/keycloak_makepad?sslmode=disable
postgres://keycloak_vestiaire_app:<secret>@<db-vm-host>:5432/keycloak_vestiaire?sslmode=disable
```

Stacks deployed through this repository's shared overlay network should use the `makepad-postgres` alias instead:

```text
postgres://keycloak_vif_app:<secret>@makepad-postgres:5432/keycloak_vif?sslmode=disable
postgres://keycloak_makepad_app:<secret>@makepad-postgres:5432/keycloak_makepad?sslmode=disable
postgres://keycloak_vestiaire_app:<secret>@makepad-postgres:5432/keycloak_vestiaire?sslmode=disable
```

Le Petit Coin uses the app-specific overlay alias:

```text
postgres://le_petit_coin_canary_app:<secret>@makepad-postgres-le-petit-coin:5432/le_petit_coin_canary?sslmode=disable
postgres://le_petit_coin_app:<secret>@makepad-postgres-le-petit-coin:5432/le_petit_coin?sslmode=disable
```

## Validation

Run the local static checks before opening a deployment PR:

```bash
bash scripts/validate-postgres-config.sh
```
