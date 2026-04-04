# Repository Conventions

## Deploy Layout

- This repository owns the shared PostgreSQL stack.
- Application repositories should consume the shared DB network and connect to `makepad-postgres`.
- Use app-scoped network secret names in this shared repo, for example `DEPLOY_CATWLK_DB_NETWORK`.
- Canary and production overrides live under `envs/<environment>/compose.yml`.
- Database env files live under `envs/<environment>/.env.db`.

## Placement

- PostgreSQL is pinned with `node.labels.infra.makepad.role == postgres`.

## Documentation

- Keep `README.md` and workflow instructions aligned with network names, bootstrap instructions, and deployment steps.
