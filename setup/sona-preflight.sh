#!/usr/bin/env bash
set -euo pipefail

script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

log() {
  printf '[sona-preflight] %s\n' "$*"
}

sentinel_dir="${PERSONALISATION_STATE_DIR:-$HOME/.builderos-personalisation}"
sentinel_log="$sentinel_dir/sona-preflight.log"
sentinel_out="$sentinel_dir/sona-preflight.out"
sentinel_pid="$sentinel_dir/sona-preflight.pid"
worker_script="$sentinel_dir/sona-preflight-worker.sh"

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

backend_exec() {
  docker_compose exec -T backend sh -lc "$1"
}

start_backend() {
  if docker_compose config --services | grep -qx clickhouse; then
    docker_compose up -d --scale clickhouse=0 backend
  else
    docker_compose up -d backend
  fi
}

wait_for_backend_deps() {
  local timeout_seconds="$1"
  local deadline=$((SECONDS + timeout_seconds))

  log_step "waiting for backend deps"

  while [ "$SECONDS" -lt "$deadline" ]; do
    if backend_exec 'test -d /app/deps/phoenix'; then
      log_step "backend deps ready"
      return 0
    fi

    sleep 5
  done

  log_step "timed out waiting for backend deps after ${timeout_seconds}s"
  return 1
}

start_background_worker() {
  mkdir -p "$sentinel_dir"
  : >"$sentinel_out"
  cp "$script_path" "$worker_script"
  chmod +x "$worker_script"

  log_step "starting background worker"
  env \
    PERSONALISATION_STATE_DIR="$sentinel_dir" \
    SONA_PREFLIGHT_BACKGROUND_WORKER=true \
    nohup bash "$worker_script" >"$sentinel_out" 2>&1 &

  printf '%s\n' "$!" >"$sentinel_pid"
  log_step "background worker pid: $!"
}

run_preflight() {
  local project_root
  local compile_test_env
  local deps_timeout

  project_root="$(find_project_root || true)"

  if [ -z "$project_root" ]; then
    log_step "no Sona project checkout found; skipping"
    return 0
  fi

  if [ ! -f "$project_root/docker-compose.yml" ] || [ ! -f "$project_root/backend/start-dev.sh" ]; then
    log_step "project at $project_root is not the Sona Docker layout; skipping"
    return 0
  fi

  if ! command -v docker >/dev/null 2>&1; then
    log_step "docker is unavailable; skipping"
    return 0
  fi

  cd "$project_root"
  mkdir -p logs

  compile_test_env="${SONA_PREFLIGHT_COMPILE_TEST_ENV:-true}"
  deps_timeout="${SONA_PREFLIGHT_DEPS_TIMEOUT:-600}"

  log_step "project root: $project_root"
  log_step "starting backend via docker compose"
  start_backend

  if [ "$compile_test_env" = "true" ]; then
    wait_for_backend_deps "$deps_timeout"
    log_step "compiling MIX_ENV=test via docker compose run --rm backend"
    backend_shell 'MIX_ENV=test mix deps.get && MIX_ENV=test mix compile'
  else
    log_step "test environment compile disabled"
  fi
}

if [ "${SONA_PREFLIGHT_BACKGROUND_WORKER:-false}" != "true" ] && [ "${SONA_PREFLIGHT_BACKGROUND:-true}" = "true" ]; then
  start_background_worker
  exit 0
fi

if [ "${SONA_PREFLIGHT_BACKGROUND_WORKER:-false}" = "true" ]; then
  log_step "background worker started"
fi

trap 'status=$?; set +e; if [ "$status" -eq 0 ]; then log_step "done"; else log_step "failed with exit $status"; fi' EXIT

run_preflight
