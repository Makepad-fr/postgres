# Makepad Postgres

Shared PostgreSQL deployment for Makepad-fr applications.

This repository owns the shared PostgreSQL server that application repositories connect to over a shared external overlay network. Application repositories should not deploy PostgreSQL directly in canary or production.

## Layout

- `compose.yml`: base PostgreSQL service definition
- `envs/canary/compose.yml`: canary Swarm overrides
- `envs/canary/.env.db`: canary PostgreSQL settings
- `envs/production/compose.yml`: production Swarm overrides
- `envs/production/.env.db`: production PostgreSQL settings

## Networks

The database joins a shared external overlay network:

- `${DEPLOY_CATWLK_DB_NETWORK}`

Application stacks attach to the same network and connect to the stable service alias `makepad-postgres`.

## Node Labels

Pin the shared PostgreSQL server to the dedicated database node:

```bash
docker node update --label-add infra.makepad.role=postgres <db-node>
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

The workflow deploys only the PostgreSQL stack. If the shared database network does not exist yet, it is created on the manager before deployment.

## Application Databases

Create one database and one dedicated user per application.

Example for Catwlk:

```sql
CREATE ROLE catwlk_app LOGIN PASSWORD 'change-me';
CREATE DATABASE catwlk OWNER catwlk_app;
```

Catwlk can then connect with:

```text
postgres://catwlk_app:change-me@makepad-postgres:5432/catwlk?sslmode=disable
```

If you run this on an existing server, use your preferred idempotent provisioning approach or wrap it in a `DO` block and `psql` checks.
