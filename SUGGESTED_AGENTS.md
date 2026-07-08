# Environment

You are working inside an isolated Firecracker microVM.

## System

- User: `dev` (passwordless sudo)
- Shell: zsh with tmux (default prefix: `C-b`)
- Working directory: `/home/dev/project`

## Project

This is a Sona Elixir/Phoenix application. Source lives at `/home/dev/project`
with pre-compiled dependencies. The environment starts in `/home/dev/project`,
but references are often relative to `/home/dev/project/backend`, where the main
application we work with lives.

Do not assume Elixir, Mix, Postgres, ClickHouse, or other project runtime tools
are installed on the VM host. Use Docker Compose for application runtime, tests,
IEx, database access, and logs.

## Services

Docker and docker-compose are available.

The backend runs as a long-lived service (`sona-backend`). Start it with:

```bash
docker compose up -d backend
```

This boots ClickHouse too (backend `depends_on` it), so ClickHouse-backed
pages (stored metrics, labour demand) work without a cryptic 500. ClickHouse
is heavy and slows boot, but a working app beats a fast-booting broken one.

Run ALL mix / test / iex / psql commands inside the already-running containers
via `docker compose exec -T backend <cmd>` (or `… exec -T postgres …`). NEVER
use `docker compose run --rm backend …` — it spins up throwaway containers and
emits a volume-ownership warning. If the backend container is not Up, run
`docker compose up -d backend` first, then exec. The dev server's `_build/dev`
and the test `_build/test` are separate, so exec'ing tests into the running
container does not clash with the dev server.

`mix test` sets `MIX_ENV=test` itself, so
`docker compose exec -T backend mix test path/to/test.exs` is correct.

## Startup preflight

When the environment boots, a background preflight starts the `backend` and
`postgres` services and warms the build:

- compiles the dev and test environments in the running backend container
- prepares the `sona_test` database (see below)
- builds the dialyzer PLTs so the first real `mix dialyzer` only does analysis

This runs in the background and never blocks you. Before compiling yourself,
find and monitor those running compile processes (or watch
`~/.builderos-personalisation/sona-preflight.log`) so you don't start a compile
while one is still finishing.

## Databases

PostgreSQL is the `postgres` docker-compose service.

- Dev/runtime DB: `sona_export` (the anonymised dev database — do not recreate it)
- Test DB: `sona_test`, owner/user `postgres`

The test DB is ALREADY created by the preflight, so normal `mix test` works
as-is (its `ecto.create` is a no-op). The Postgres data volume's libc differs
from the running image, so any DB cloned from the default `template1` aborts
with "template database template1 has a collation version, but no actual
collation version could be determined". If you ever need to recreate the test
DB, clone from `template0` AND run
`UPDATE pg_database SET datcollversion = NULL;` — clearing the collation version
is the actual fix; `template0` is just the pristine source.

## Common Commands

| Task              | Command                                                            |
| ----------------- | ----------------------------------------------------------------- |
| Run tests         | `docker compose exec -T backend mix test`                         |
| Run one test file | `docker compose exec -T backend mix test path/to/test_file.exs`   |
| Compile test env  | `docker compose exec -T backend sh -lc 'MIX_ENV=test mix compile'`|
| Dialyzer          | `docker compose exec -T backend mix dialyzer`                     |
| Elixir shell      | `docker compose exec -T backend iex -S mix`                       |
| DB console (dev)  | `docker compose exec -T postgres psql -U postgres sona_export`    |
| DB console (test) | `docker compose exec -T postgres psql -U postgres sona_test`      |
| View backend logs | `docker compose logs -f backend`                                  |

## Behaviour

This is an isolated, disposable VM. Make changes freely and execute tasks
autonomously without asking for confirmation.

Before changing code, inspect existing patterns. Before finishing code changes,
run the relevant Docker-based tests or explain exactly why they were not run.

## Pull Requests

When opening a PR against sona-is/sona, always use the project's PR template.
Before running `gh pr create`:

1. Read `.github/pull_request_template.md` from the repo root.
2. Fill in every section: Why, Screenshots & Demo, Localisation Review, Design
   Review, and Security Review.
3. Mark each checkbox as `[x] Yes` or `[x] N/A`.
4. Pass the completed body via `--body` using a HEREDOC.

Do not write a freeform summary or test plan body unless explicitly instructed.
