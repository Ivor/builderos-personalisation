#!/usr/bin/env bash
# -E so the ERR trap is inherited into functions; without it a failure inside
# wait_for_*/prepare_test_database/backend_exec would abort silently.
set -Eeuo pipefail

script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

log() {
  printf '[sona-preflight] %s\n' "$*"
}

sentinel_dir="${PERSONALISATION_STATE_DIR:-$HOME/.builderos-personalisation}"
sentinel_log="$sentinel_dir/sona-preflight.log"
sentinel_out="$sentinel_dir/sona-preflight.out"
sentinel_pid="$sentinel_dir/sona-preflight.pid"
sentinel_status="$sentinel_dir/sona-preflight.status"
worker_script="$sentinel_dir/sona-preflight-worker.sh"

# The step currently running, so the ERR/EXIT traps can name what failed
# instead of only reporting an exit code.
current_step="starting"

write_sentinel() {
  mkdir -p "$sentinel_dir"
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$sentinel_log"
}

# A single-line machine-readable status agents can cat: running | ok | failed
write_status() {
  mkdir -p "$sentinel_dir"
  printf '%s\n' "$*" >"$sentinel_status"
}

log_step() {
  current_step="$*"
  log "$*"
  write_sentinel "$*"
}

# BuilderOS materialises the per-session branch checkout at this fixed path
# (WORKSPACE_PATH in the orchestrator: vm_orchestrator/config.py). It is the tree
# the agent edits and the only checkout we ever want the dev stack to serve — the
# baked /home/dev/project sits on master and is never the working tree. The path
# is a hardcoded constant on the BuilderOS side with no env to read it from, so
# we hardcode it too. run_preflight's layout guard skips cleanly when this isn't
# a Sona checkout (e.g. a non-Sona VM).
find_project_root() {
  printf '%s\n' "/workspace/project"
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
  docker_compose up -d backend
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

# The dev server is up once Phoenix is accepting TCP connections on its HTTP
# port (published to the host as localhost:4000). A bare /dev/tcp connect avoids
# depending on curl being installed on the host or in the container.
wait_for_dev_server() {
  local timeout_seconds="$1"
  local host="${SONA_PREFLIGHT_DEV_SERVER_HOST:-localhost}"
  local port="${SONA_PREFLIGHT_DEV_SERVER_PORT:-4000}"
  local deadline=$((SECONDS + timeout_seconds))

  log_step "waiting for dev server at ${host}:${port}"

  while [ "$SECONDS" -lt "$deadline" ]; do
    # The connect runs in a subshell so its failure feeds the `if` instead of
    # tripping the ERR trap, and the fd is closed when that subshell exits.
    if (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null; then
      log_step "dev server responding on ${host}:${port}"
      return 0
    fi

    sleep 3
  done

  log_step "timed out waiting for dev server after ${timeout_seconds}s"
  return 1
}

# Export a flag every new agent shell can read. .zshenv is sourced by every zsh
# invocation (login/non-login, interactive or not), so once this is written the
# flag is set in every shell the agent spawns. Presence of the var == the dev
# server was confirmed up by the preflight.
mark_dev_server_ready() {
  local profile="$HOME/.zshenv"
  local marker='export SONA_DEV_SERVER_READY=1  # set by sona-preflight once the dev server is up'

  if ! grep -qF 'SONA_DEV_SERVER_READY' "$profile" 2>/dev/null; then
    printf '%s\n' "$marker" >>"$profile"
  fi

  log_step "dev server ready; exported SONA_DEV_SERVER_READY=1 via $profile"
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
  local wait_dev_server
  local dev_server_timeout

  project_root="$(find_project_root)"

  if [ ! -f "$project_root/docker-compose.yml" ] || [ ! -f "$project_root/backend/start-dev.sh" ]; then
    log_step "project at $project_root is not the Sona Docker layout; skipping"
    return 0
  fi

  if ! command -v docker >/dev/null 2>&1; then
    log_step "docker is unavailable; skipping"
    return 0
  fi

  # docker compose must run from the project root so it finds docker-compose.yml.
  # (No host `mkdir` here: preflight runs as a different user than the project
  # owner, so it can't write into $project_root — and nothing in this script
  # writes to a host logs/ dir anyway; all output goes to $sentinel_dir.)
  cd "$project_root"

  compile_test_env="${SONA_PREFLIGHT_COMPILE_TEST_ENV:-true}"
  dialyzer_warmup="${SONA_PREFLIGHT_DIALYZER:-true}"
  deps_timeout="${SONA_PREFLIGHT_DEPS_TIMEOUT:-600}"
  postgres_timeout="${SONA_PREFLIGHT_POSTGRES_TIMEOUT:-120}"
  wait_dev_server="${SONA_PREFLIGHT_WAIT_DEV_SERVER:-true}"
  dev_server_timeout="${SONA_PREFLIGHT_DEV_SERVER_TIMEOUT:-300}"

  log_step "project root: $project_root"

  # Postgres FIRST, on its own: remote-DB worktrees (docker-free-worktree
  # --remote-db) tunnel into this VM's postgres and need it seconds after boot.
  # The full `up -d backend` below drags up the entire stack (backend,
  # ClickHouse, satellites — minutes under post-boot IO); postgres alone starts
  # in seconds, and the backend graph then treats it as already satisfied.
  log_step "starting postgres via docker compose (postgres-first)"
  docker_compose up -d postgres

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

  # Last: confirm the dev server is actually serving and export the flag agents
  # check. Runs after the warm steps so those never wait behind server boot.
  if [ "$wait_dev_server" = "true" ]; then
    wait_for_dev_server "$dev_server_timeout"
    mark_dev_server_ready
  else
    log_step "dev server wait disabled"
  fi
}

if [ "${SONA_PREFLIGHT_BACKGROUND_WORKER:-false}" != "true" ] && [ "${SONA_PREFLIGHT_BACKGROUND:-true}" = "true" ]; then
  start_background_worker
  exit 0
fi

if [ "${SONA_PREFLIGHT_BACKGROUND_WORKER:-false}" = "true" ]; then
  log_step "background worker started"
  write_status "running"
fi

# ERR fires at the exact failing command (before EXIT), so we capture which
# step, which line, and the command itself — the info the old "exit N" hid.
# No `set +e` here: it would disable errexit for the rest of the script and
# defeat fail-fast. The trap body only appends to a log, so it can't trip errexit.
trap 'rc=$?; write_sentinel "ERROR exit $rc at line $LINENO during step \"$current_step\" (cmd: $BASH_COMMAND)"' ERR

trap 'status=$?; set +e; if [ "$status" -eq 0 ]; then log_step "done"; write_status "ok"; else write_sentinel "FAILED exit $status during step \"$current_step\""; write_status "failed: $current_step (exit $status)"; fi' EXIT

run_preflight
