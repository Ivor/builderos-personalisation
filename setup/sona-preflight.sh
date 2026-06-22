#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[sona-preflight] %s\n' "$*"
}

sentinel_dir="${PERSONALISATION_STATE_DIR:-$HOME/.builderos-personalisation}"
sentinel_log="$sentinel_dir/sona-preflight.log"

write_sentinel() {
  mkdir -p "$sentinel_dir"
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$sentinel_log"
}

log_step() {
  log "$*"
  write_sentinel "$*"
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

docker_compose() {
  if command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    docker compose "$@"
  fi
}

backend_shell() {
  docker_compose run --rm backend sh -lc "$1"
}

start_backend() {
  if docker_compose config --services | grep -qx clickhouse; then
    docker_compose up -d --scale clickhouse=0 backend
  else
    docker_compose up -d backend
  fi
}

project_root="$(find_project_root || true)"

if [ -z "$project_root" ]; then
  log_step "no Sona project checkout found; skipping"
  exit 0
fi

if [ ! -f "$project_root/docker-compose.yml" ] || [ ! -f "$project_root/backend/start-dev.sh" ]; then
  log_step "project at $project_root is not the Sona Docker layout; skipping"
  exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
  log_step "docker is unavailable; skipping"
  exit 0
fi

cd "$project_root"
mkdir -p logs

compile_test_env="${SONA_PREFLIGHT_COMPILE_TEST_ENV:-true}"

log_step "project root: $project_root"
log_step "starting backend via docker compose"
start_backend

if [ "$compile_test_env" = "true" ]; then
  log_step "compiling MIX_ENV=test via docker compose run --rm backend"
  backend_shell 'MIX_ENV=test mix compile'
else
  log_step "test environment compile disabled"
fi

log_step "done"
