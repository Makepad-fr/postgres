# Makepad Postgres

Shared PostgreSQL deployment for Makepad-fr applications.

This repository owns the shared PostgreSQL server. Application repositories connect either through the shared overlay network alias or through the configured DB VM host endpoint, depending on their deployment topology. Application repositories should not deploy PostgreSQL directly in canary or production.

## Layout

- `compose.yml`: base PostgreSQL service definition
- `envs/canary/compose.yml`: canary Swarm overrides
- `envs/canary/.env.db`: canary PostgreSQL settings
- `envs/production/compose.yml`: production Swarm overrides
- `envs/production/.env.db`: production PostgreSQL settings
- `bootstrap/keycloak-new-instances.sql`: idempotent SQL bootstrap for the Vif, Makepad, Vestiaire, and Runtrace Keycloak databases
- `bootstrap/runtrace-app.sql`: idempotent SQL bootstrap for the Runtrace application database
- `bootstrap/scraping-app.sql`: idempotent SQL bootstrap for the shared scraping frontier database
- `bootstrap/iceberg-catalog.sql`: idempotent SQL bootstrap for durable Iceberg catalog metadata
- `bootstrap/vestiaire-developer-platform.sql`: idempotent bootstrap for Vestiaire organizations, memberships, and API credential metadata

## Networks

The database joins external overlay networks configured through Compose:

- `${MAKEPAD_POSTGRES_DB_NETWORK}`
- `${MAKEPAD_POSTGRES_LE_PETIT_COIN_DB_NETWORK}`

Production also joins production-only application-specific external overlay networks:

- `${MAKEPAD_POSTGRES_VIF_DB_NETWORK}`
- `${MAKEPAD_POSTGRES_SCRAPING_DB_NETWORK}`

The manual deploy workflow sources these Compose variables from environment secrets with this mapping:

- `${MAKEPAD_POSTGRES_DB_NETWORK}` <- `DEPLOY_CATWLK_DB_NETWORK`
- `${MAKEPAD_POSTGRES_LE_PETIT_COIN_DB_NETWORK}` <- `DEPLOY_LE_PETIT_COIN_DB_NETWORK`
- `${MAKEPAD_POSTGRES_VIF_DB_NETWORK}` <- `DEPLOY_VIF_DB_NETWORK` production only
- `${MAKEPAD_POSTGRES_SCRAPING_DB_NETWORK}` <- `DEPLOY_SCRAPING_DB_NETWORK` production only

Application network topology is owned by the consuming application repositories. New Keycloak instances keep their own DB-facing Docker networks in the Keycloak repository and connect to this PostgreSQL server through the configured DB endpoint.

When using this repository's overlay-network deployment model, application stacks attached to the shared database network should use the stable service alias `makepad-postgres`. Le Petit Coin stacks attach through their app-specific database network and should use `makepad-postgres-le-petit-coin`. The production VIF stack attaches through its production-only app-specific database network and should use `makepad-postgres-vif`. The production Scraping crawler stack attaches through its production-only app-specific database network and should use `makepad-postgres-scraping`. Canary does not attach the VIF or Scraping networks. The current production Keycloak deployment is separate from this stack and uses the DB VM host address instead; that host-based path depends on the standalone DB VM deployment exposing PostgreSQL on the VM host.

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

Production additionally requires:

- `DEPLOY_VIF_DB_NETWORK`
- `DEPLOY_VIF_DB_PASSWORD`
- `DEPLOY_SCRAPING_DB_NETWORK`
- `DEPLOY_SCRAPING_DB_PASSWORD`
- `DEPLOY_FASHION_CATALOG_READER_PASSWORD`

Production can override the VIF database and role names with `DEPLOY_VIF_DB_NAME` and `DEPLOY_VIF_DB_USER`; both default to `vif`.
Production can override the Scraping database and role names with `DEPLOY_SCRAPING_DB_NAME` and `DEPLOY_SCRAPING_DB_USER`; they default to `scraping` and `scraping_crawler`.

`DEPLOY_SSH_USER` must be a non-root deployment account with the Docker permissions needed to create overlay networks and deploy the stack. The workflow rejects `DEPLOY_SSH_USER=root`.

The workflow deploys only the PostgreSQL stack. If one of the configured database networks does not exist yet, it is created on the manager before deployment.

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

The Vestiaire developer platform uses an isolated database and role:

| Application | Database | Role |
| --- | --- | --- |
| Vestiaire developer platform | `vestiaire_developer` | `vestiaire_developer_app` |

Run the idempotent bootstrap with generated passwords. `POSTGRES_ADMIN_URL` must be a PostgreSQL superuser connection URI for the target server, usually using the `postgres` role, because the bootstrap creates roles, sets passwords, creates databases, and assigns database ownership. For example: `postgres://postgres@<db-vm-host>:5432/postgres?sslmode=disable`.

```bash
: "${POSTGRES_ADMIN_URL:?set POSTGRES_ADMIN_URL to a PostgreSQL superuser connection URI}"
: "${KEYCLOAK_VIF_DB_PASSWORD:?set KEYCLOAK_VIF_DB_PASSWORD to a generated password}"
: "${KEYCLOAK_MAKEPAD_DB_PASSWORD:?set KEYCLOAK_MAKEPAD_DB_PASSWORD to a generated password}"
: "${KEYCLOAK_VESTIAIRE_DB_PASSWORD:?set KEYCLOAK_VESTIAIRE_DB_PASSWORD to a generated password}"
: "${KEYCLOAK_RUNTRACE_DB_PASSWORD:?set KEYCLOAK_RUNTRACE_DB_PASSWORD to a generated password}"
: "${SCRAPING_DB_PASSWORD:?set SCRAPING_DB_PASSWORD to a generated password}"
: "${FASHION_CATALOG_READER_PASSWORD:?set FASHION_CATALOG_READER_PASSWORD to a generated password}"
: "${RUNTRACE_DB_PASSWORD:?set RUNTRACE_DB_PASSWORD to a generated password}"
: "${VESTIAIRE_DEVELOPER_DB_PASSWORD:?set VESTIAIRE_DEVELOPER_DB_PASSWORD to a generated password}"

psql "$POSTGRES_ADMIN_URL" \
  -v keycloak_vif_app_password="$KEYCLOAK_VIF_DB_PASSWORD" \
  -v keycloak_makepad_app_password="$KEYCLOAK_MAKEPAD_DB_PASSWORD" \
  -v keycloak_vestiaire_app_password="$KEYCLOAK_VESTIAIRE_DB_PASSWORD" \
  -v keycloak_runtrace_app_password="$KEYCLOAK_RUNTRACE_DB_PASSWORD" \
  -f bootstrap/keycloak-new-instances.sql

psql "$POSTGRES_ADMIN_URL" \
  -v runtrace_app_password="$RUNTRACE_DB_PASSWORD" \
  -f bootstrap/runtrace-app.sql

psql "$POSTGRES_ADMIN_URL" \
  -v vestiaire_developer_app_password="$VESTIAIRE_DEVELOPER_DB_PASSWORD" \
  -f bootstrap/vestiaire-developer-platform.sql

psql "$POSTGRES_ADMIN_URL" \
  -v scraping_crawler_password="$SCRAPING_DB_PASSWORD" \
  -v fashion_catalog_reader_password="$FASHION_CATALOG_READER_PASSWORD" \
  -f bootstrap/scraping-app.sql

# Provision or rotate only the catalog reader without touching the crawler role.
psql "$POSTGRES_ADMIN_URL" \
  -v fashion_catalog_reader_password="$FASHION_CATALOG_READER_PASSWORD" \
  -f bootstrap/fashion-catalog-reader.sql
```

The current production Keycloak environments connect with the DB VM host:

```text
postgres://keycloak_vif_app:<secret>@<db-vm-host>:5432/keycloak_vif?sslmode=disable
postgres://keycloak_makepad_app:<secret>@<db-vm-host>:5432/keycloak_makepad?sslmode=disable
postgres://keycloak_vestiaire_app:<secret>@<db-vm-host>:5432/keycloak_vestiaire?sslmode=disable
postgres://keycloak_runtrace_app:<secret>@<db-vm-host>:5432/keycloak_runtrace?sslmode=disable
postgres://runtrace_app:<secret>@<db-vm-host>:5432/runtrace?sslmode=disable
postgres://vestiaire_developer_app:<secret>@<db-vm-host>:5432/vestiaire_developer?sslmode=disable
```

Stacks deployed through this repository's shared overlay network should use the `makepad-postgres` alias instead:

```text
postgres://keycloak_vif_app:<secret>@makepad-postgres:5432/keycloak_vif?sslmode=disable
postgres://keycloak_makepad_app:<secret>@makepad-postgres:5432/keycloak_makepad?sslmode=disable
postgres://keycloak_vestiaire_app:<secret>@makepad-postgres:5432/keycloak_vestiaire?sslmode=disable
postgres://keycloak_runtrace_app:<secret>@makepad-postgres:5432/keycloak_runtrace?sslmode=disable
postgres://runtrace_app:<secret>@makepad-postgres:5432/runtrace?sslmode=disable
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

The production Scraping crawler uses its app-specific overlay alias and deploy-time provisioned database:

```text
postgres://scraping_crawler:<password>@makepad-postgres-scraping:5432/scraping
```

The fashion product catalog inventory indexer uses a separate read-only role on the same database:

```text
postgres://fashion_catalog_reader:<password>@makepad-postgres-scraping:5432/scraping
```

`fashion_catalog_reader` receives `CONNECT`, schema `USAGE`, and `SELECT` on current and future tables created by `scraping_crawler`. It cannot mutate crawler frontier or inventory state. The catalog deployment should store its password as a dedicated external Docker secret.

If production overrides `DEPLOY_SCRAPING_DB_NAME` or `DEPLOY_SCRAPING_DB_USER`, use those values in the connection URI.

## Validation

Run the local static checks before opening a deployment PR:

```bash
bash scripts/validate-postgres-config.sh
```
