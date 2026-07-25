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
catalog_reader_sql = (root / "bootstrap/fashion-catalog-reader.sql").read_text()
iceberg_sql = (root / "bootstrap/iceberg-catalog.sql").read_text()
developer_platform_sql = (root / "bootstrap/vestiaire-developer-platform.sql").read_text()

require("network_mode: host" in compose, "Postgres compose must match the live host-network deployment.")
require("docker inspect \"${container_name}\"" in workflow, "Workflow must provision through the running DB container.")
require("docker stack deploy" not in workflow, "Workflow must not use Swarm for the DB VM.")
require("DEPLOY_SSH_USER must not be root" in workflow, "Workflow must reject root SSH users.")
require("DEPLOY_SCRAPING_DB_PASSWORD" in workflow, "Workflow must require the scraping DB password secret.")
require("DEPLOY_FASHION_CATALOG_READER_PASSWORD" in workflow, "Workflow must require the fashion catalog reader password secret.")
require("scraping_crawler" in scraping_sql, "Scraping bootstrap must create the scraping_crawler role.")
require("CREATE DATABASE scraping OWNER scraping_crawler" in scraping_sql, "Scraping bootstrap must create the scraping database.")
require("ALTER ROLE scraping_crawler LOGIN PASSWORD :'scraping_crawler_password'" in scraping_sql, "Scraping bootstrap must set the role password from a psql variable.")
require("NULLIF(btrim(:'scraping_crawler_password'), '')" in scraping_sql, "Scraping bootstrap must reject empty passwords.")
require("fashion_catalog_reader" in scraping_sql, "Scraping bootstrap must create the fashion catalog reader role.")
require("ALTER ROLE fashion_catalog_reader LOGIN PASSWORD :'fashion_catalog_reader_password'" in scraping_sql, "Scraping bootstrap must set the reader password from a psql variable.")
require("NULLIF(btrim(:'fashion_catalog_reader_password'), '')" in scraping_sql, "Scraping bootstrap must reject an empty reader password.")
require("GRANT SELECT ON ALL TABLES IN SCHEMA public TO fashion_catalog_reader" in scraping_sql, "Reader role must receive SELECT on current scraping tables.")
require("ALTER DEFAULT PRIVILEGES FOR ROLE scraping_crawler" in scraping_sql, "Reader role must receive SELECT on future scraping tables.")
require("pg_advisory_lock" in scraping_sql and "pg_advisory_unlock" in scraping_sql, "Scraping bootstrap must serialize concurrent runs.")
require("ALTER ROLE fashion_catalog_reader LOGIN PASSWORD :'fashion_catalog_reader_password'" in catalog_reader_sql, "Dedicated catalog reader bootstrap must set its password from a psql variable.")
require("GRANT SELECT ON ALL TABLES IN SCHEMA public TO fashion_catalog_reader" in catalog_reader_sql, "Dedicated catalog reader bootstrap must grant read access to current tables.")
require("ALTER DEFAULT PRIVILEGES FOR ROLE scraping_crawler" in catalog_reader_sql, "Dedicated catalog reader bootstrap must grant read access to future crawler tables.")
require("pg_advisory_lock" in catalog_reader_sql and "pg_advisory_unlock" in catalog_reader_sql, "Dedicated catalog reader bootstrap must serialize concurrent runs.")
require("iceberg_catalog" in iceberg_sql, "Iceberg bootstrap must create the Iceberg catalog role and database.")
require("NULLIF(btrim(:'iceberg_catalog_password'), '')" in iceberg_sql, "Iceberg bootstrap must reject empty passwords.")
require("pg_advisory_lock" in iceberg_sql and "pg_advisory_unlock" in iceberg_sql, "Iceberg bootstrap must serialize concurrent runs.")
require("vestiaire_developer_app" in developer_platform_sql, "Developer platform bootstrap must create its application role.")
require("CREATE DATABASE vestiaire_developer OWNER vestiaire_developer_app" in developer_platform_sql, "Developer platform bootstrap must create its database.")
require("ALTER ROLE vestiaire_developer_app" in developer_platform_sql and "PASSWORD :'vestiaire_developer_app_password'" in developer_platform_sql, "Developer platform bootstrap must set its password from a psql variable.")
require("NULLIF(btrim(:'vestiaire_developer_app_password'), '')" in developer_platform_sql, "Developer platform bootstrap must reject an empty password.")
require("pg_advisory_lock" in developer_platform_sql and "pg_advisory_unlock" in developer_platform_sql, "Developer platform bootstrap must serialize concurrent runs.")
PY
