#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[sona-preflight] %s\n' "$*"
}

find_project_root() {
  if [ -n "${BUILDEROS_PROJECT_ROOT:-}" ]; then
    printf '%s\n' "$BUILDEROS_PROJECT_ROOT"
    return 0
  fi

  if [ -n "${PROJECT_ROOT:-}" ]; then
    printf '%s\n' "$PROJECT_ROOT"
    return 0
  fi

  for candidate in /home/dev/project "$HOME/project" "$PWD"; do
    if [ -f "$candidate/docker-compose.yml" ] && [ -f "$candidate/backend/start-dev.sh" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

wait_for_log_line() {
  local container="$1"
  local pattern="$2"
  local timeout_seconds="$3"
  local deadline

  deadline=$((SECONDS + timeout_seconds))

  while [ "$SECONDS" -lt "$deadline" ]; do
    if docker logs "$container" 2>&1 | grep -q "$pattern"; then
      return 0
    fi

    sleep 5
  done

  return 1
}

docker_compose() {
  if command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    docker compose "$@"
  fi
}

run_in_backend() {
  docker exec sona-dev env -u DISABLE_OBAN zsh -lc "$1"
}

project_root="$(find_project_root || true)"

if [ -z "$project_root" ]; then
  log "no Sona project checkout found; skipping"
  exit 0
fi

if [ ! -f "$project_root/docker-compose.yml" ] || [ ! -f "$project_root/backend/start-dev.sh" ]; then
  log "project at $project_root is not the Sona Docker layout; skipping"
  exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
  log "docker is unavailable; skipping"
  exit 0
fi

cd "$project_root"
mkdir -p logs

app_timeout="${SONA_PREFLIGHT_APP_TIMEOUT:-900}"
compile_test_env="${SONA_PREFLIGHT_COMPILE_TEST_ENV:-true}"

log "project root: $project_root"

if docker ps -a --format '{{.Names}}' | grep -qx 'sona-dev'; then
  log "sona-dev container already exists; reusing it"
else
  log "building and starting dev container"
  docker_compose run --build -d --service-ports --name sona-dev backend /app/start-dev.sh
fi

log "waiting for Phoenix readiness"
if ! wait_for_log_line sona-dev "Access BackendWeb.Endpoint" "$app_timeout"; then
  log "timed out waiting for Phoenix readiness after ${app_timeout}s"
  docker logs --tail 120 sona-dev || true
  exit 1
fi

log "preparing sona_test without touching the anonymised dev database"
docker exec sona-postgres-1 dropdb -U postgres --if-exists sona_test
docker exec sona-postgres-1 createdb -U postgres -T template0 sona_test

if [ "$compile_test_env" = "true" ]; then
  log "compiling MIX_ENV=test"
  run_in_backend 'MIX_ENV=test mix compile'
else
  log "test environment compile disabled"
fi

log "done"
