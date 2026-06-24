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

backend_exec() {
  docker_compose exec -T backend sh -lc "$1"
}

postgres_exec() {
  docker_compose exec -T postgres "$@"
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

wait_for_postgres() {
  local timeout_seconds="$1"
  local deadline=$((SECONDS + timeout_seconds))

  log_step "waiting for postgres"

  while [ "$SECONDS" -lt "$deadline" ]; do
    if postgres_exec pg_isready -U postgres -d postgres >/dev/null 2>&1; then
      log_step "postgres ready"
      return 0
    fi

    sleep 3
  done

  log_step "timed out waiting for postgres after ${timeout_seconds}s"
  return 1
}

# The Postgres data volume was built with a different libc than the running
# image, so any database cloned from the default template1 aborts with
# "template database template1 has a collation version, but no actual collation
# version could be determined". The test mix alias runs ecto.create, so mix test
# fails unless sona_test already exists. Clear the stale collation-version
# records (the actual fix) and pre-create sona_test from the pristine template0.
prepare_test_database() {
  log_step "clearing stale collation version records"
  postgres_exec psql -U postgres -d postgres -c "UPDATE pg_database SET datcollversion = NULL;"

  if postgres_exec psql -U postgres -d postgres -tc "SELECT 1 FROM pg_database WHERE datname='sona_test'" | grep -q 1; then
    log_step "sona_test already exists"
  else
    log_step "creating sona_test from template0"
    postgres_exec psql -U postgres -d postgres -c "CREATE DATABASE sona_test TEMPLATE template0;"
  fi
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
  local dialyzer_warmup
  local deps_timeout
  local postgres_timeout

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
  dialyzer_warmup="${SONA_PREFLIGHT_DIALYZER:-true}"
  deps_timeout="${SONA_PREFLIGHT_DEPS_TIMEOUT:-600}"
  postgres_timeout="${SONA_PREFLIGHT_POSTGRES_TIMEOUT:-120}"

  log_step "project root: $project_root"
  log_step "starting backend via docker compose"
  start_backend

  if [ "$compile_test_env" = "true" ] || [ "$dialyzer_warmup" = "true" ]; then
    wait_for_backend_deps "$deps_timeout"
  fi

  if [ "$compile_test_env" = "true" ]; then
    wait_for_postgres "$postgres_timeout"
    prepare_test_database
    log_step "running MIX_ENV=test ecto.migrate in backend container"
    backend_exec 'MIX_ENV=test mix ecto.migrate --quiet'
    log_step "warming MIX_ENV=test build in backend container"
    backend_exec 'MIX_ENV=test mix compile'
  else
    log_step "test environment compile disabled"
  fi

  # Build the dialyzer PLTs (the slow part) so the agent's first `mix dialyzer`
  # is analysis-only and fast. PLTs are per-MIX_ENV; warm the same dev env the
  # agent runs dialyzer in. Runs in the same backend container, in the
  # background worker, so it never blocks agent startup.
  if [ "$dialyzer_warmup" = "true" ]; then
    log_step "warming dialyzer PLT in backend container"
    backend_exec 'mix dialyzer --plt'
  else
    log_step "dialyzer PLT warmup disabled"
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
