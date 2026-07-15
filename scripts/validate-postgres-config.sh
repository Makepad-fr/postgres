#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "${repo_root}" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])

def require(condition, message):
    if not condition:
        raise SystemExit(message)

compose = (root / "compose.yml").read_text()
workflow = (root / ".github/workflows/manual-deploy.yml").read_text()
scraping_sql = (root / "bootstrap/scraping-app.sql").read_text()

require("network_mode: host" in compose, "Postgres compose must match the live host-network deployment.")
require("docker inspect \"${container_name}\"" in workflow, "Workflow must provision through the running DB container.")
require("docker stack deploy" not in workflow, "Workflow must not use Swarm for the DB VM.")
require("DEPLOY_SSH_USER must not be root" in workflow, "Workflow must reject root SSH users.")
require("DEPLOY_SCRAPING_DB_PASSWORD" in workflow, "Workflow must require the scraping DB password secret.")
require("scraping_crawler" in scraping_sql, "Scraping bootstrap must create the scraping_crawler role.")
require("CREATE DATABASE scraping OWNER scraping_crawler" in scraping_sql, "Scraping bootstrap must create the scraping database.")
require("ALTER ROLE scraping_crawler LOGIN PASSWORD :'scraping_crawler_password'" in scraping_sql, "Scraping bootstrap must set the role password from a psql variable.")
require("NULLIF(btrim(:'scraping_crawler_password'), '')" in scraping_sql, "Scraping bootstrap must reject empty passwords.")
require("pg_advisory_lock" in scraping_sql and "pg_advisory_unlock" in scraping_sql, "Scraping bootstrap must serialize concurrent runs.")
PY
