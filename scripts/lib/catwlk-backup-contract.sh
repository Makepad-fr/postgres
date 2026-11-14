#!/usr/bin/env bash

# Sourced by the backup entrypoint and its focused contract test.
# shellcheck disable=SC2034
catwlk_databases=(catwlk_production catwlk_canary)
catwlk_postgres_image='postgres:16-alpine@sha256:721873c34ceb9f8d8fc265984940dc982404c105f19ad51be9fdc5970a6080ea'
catwlk_postgres_image_id='sha256:721873c34ceb9f8d8fc265984940dc982404c105f19ad51be9fdc5970a6080ea'

catwlk_assert_source() {
  local declared_image=$1
  local inspection
  [[ "$declared_image" == "$catwlk_postgres_image" ]] || {
    echo 'Configured PostgreSQL image does not match the reviewed Catwlk backup image.' >&2
    return 1
  }
  inspection=$(docker inspect postgres-postgres-1 --format '{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{.Config.Image}}|{{.Image}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}') || return 1
  [[ "$inspection" == "postgres|postgres|${catwlk_postgres_image}|${catwlk_postgres_image_id}|running|healthy" ]] || {
    echo 'Exact healthy production PostgreSQL container is required.' >&2
    return 1
  }
}

catwlk_forget_scoped() {
  local daily=$1 monthly=$2
  restic forget --tag catwlk-postgres-nightly --group-by host,tags \
    --keep-daily "$daily" --keep-monthly "$monthly" --prune
}
