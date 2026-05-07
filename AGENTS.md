# Repository Conventions

## Deploy Layout

- This repository owns the shared PostgreSQL stack.
- Application repositories own their app-specific network topology.
- Use app-scoped network secret names in this shared repo, for example `DEPLOY_CATWLK_DB_NETWORK`.
- Canary and production overrides live under `envs/<environment>/compose.yml`.
- Database env files live under `envs/<environment>/.env.db`.

## Placement

- PostgreSQL is pinned with `node.labels.infra.makepad.postgres == true`.

## Documentation

- Keep `README.md`, bootstrap SQL, validation scripts, and workflow instructions aligned with bootstrap instructions and deployment steps.
