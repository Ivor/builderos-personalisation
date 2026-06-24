# BuilderOS personalisation

Local personalisation repo for BuilderOS/FV VMs.

This repo follows the structure from the BuilderOS Platform Guide page
"Choosing and Customising the Agent". BuilderOS checks this repo out on each
new VM and applies `.builderos/personalisation.yaml` after the project checkout
and before the agent starts.

## What It Does

- Deep-merges safe Claude settings into `~/.claude/settings.json`.
- Deep-merges safe Codex settings into `~/.codex/config.toml`.
- Copies repo-owned Codex skills into the VM user home.
- Installs selected Claude plugins from the Sona and caveman marketplaces.
- Runs the Sona Docker preflight before the agent starts when the checked-out
  project looks like the Sona repo.
- Leaves live environment variables, OAuth files, SSH keys, GitHub tokens, and
  platform-injected credentials alone.

## What It Must Not Contain

Do not commit:

- `.env` files
- API tokens
- GitHub tokens
- Atlassian tokens
- OAuth client info files
- SSH private keys
- deploy keys
- machine-local absolute paths that only work on one laptop
- complete copies of `~/.codex/config.toml` or `~/.claude/settings.json` if they
  contain secrets

The current local Codex config contains MCP env tokens. Those are intentionally
not copied here.

Claude plugins are installed during preflight through `claude plugin
marketplace add` and `claude plugin install`. Codex skills are vendored in this
repo and copied into `~/.codex/skills`.

## Layout

```text
.builderos/personalisation.yaml
config/
  claude/settings.json
  codex/config.toml
setup/install.sh
setup/sona-preflight.sh
skills/
  claude/
  codex/
agents/
  claude/
SUGGESTED_AGENTS.md
```

## Suggested Agent Instructions

`SUGGESTED_AGENTS.md` is a reference system prompt for the FV agent running in a
Sona VM. It is not applied automatically — copy it into the agent
configuration. It documents the Docker Compose workflow (run everything via
`docker compose exec -T backend`, never `run --rm`), the `sona_test` database
and collation fix, and the dialyzer/test-build warmup that `setup/sona-preflight.sh`
performs.

## Sona Preflight

`setup/sona-preflight.sh` is the pre-agent setup path for Sona VMs. It only runs
when it can find a checkout with both `docker-compose.yml` and
`backend/start-dev.sh`.

The script:

- copies itself into `~/.builderos-personalisation/` and starts a background
  worker
- returns immediately so the agent can start while Docker setup continues
- starts the existing Compose `backend` service detached
- avoids starting ClickHouse when the Compose file defines it
- waits for backend dependencies to appear in the running backend container
- waits for the Compose `postgres` service to accept connections
- clears stale `pg_database.datcollversion` records and pre-creates the
  `sona_test` database from `template0`, so the first `mix test` does not abort
  on the `ecto.create` collation-version check
- migrates the test database with `MIX_ENV=test mix ecto.migrate --quiet`
- warms the test Mix build with `MIX_ENV=test mix compile`
- builds the dialyzer PLTs with `mix dialyzer --plt` so the first real
  `mix dialyzer` run only does analysis

All Mix and psql commands run inside the already-running Compose `backend` and
`postgres` services via `docker compose exec` — never `docker compose run --rm`,
which would spin up throwaway containers. The script does not create or modify
the anonymised dev database, and it does not install Elixir or Mix on the VM
host.

The script writes a sentinel log to:

```text
~/.builderos-personalisation/sona-preflight.log
```

The background worker's stdout/stderr goes to:

```text
~/.builderos-personalisation/sona-preflight.out
```

The worker PID is written to:

```text
~/.builderos-personalisation/sona-preflight.pid
```

`setup/install.sh` also writes:

```text
~/.builderos-personalisation/install.log
```

Useful overrides:

```bash
SONA_PREFLIGHT_BACKGROUND=false            # run preflight synchronously
SONA_PREFLIGHT_COMPILE_TEST_ENV=false      # skip test DB prep + MIX_ENV=test compile
SONA_PREFLIGHT_DIALYZER=false              # skip dialyzer PLT warmup
SONA_PREFLIGHT_DEPS_TIMEOUT=600            # seconds to wait for backend deps
SONA_PREFLIGHT_POSTGRES_TIMEOUT=120        # seconds to wait for postgres
BUILDEROS_PROJECT_ROOT=/home/dev/project
```

## FV Reference

Once this is in a private GitHub repo, point FV at it using a deploy-key
credential reference, not a raw key:

```bash
fv personalisation set \
  --url git@github.com:Ivor/builderos-personalisation.git \
  --deploy-key <deploy-key-id> \
  --required \
  --timeout 900
```

For a one-off task or session:

```bash
fv task --personalisation main "Task prompt"
fv session --personalisation main
```

## Credential Safety

Personalisation is not where server secrets should live. BuilderOS injects the
agent API credentials into the VM at provision time, and private personalisation
repos use a connected deploy-key credential by ID.

This repo's script does not export, unset, rewrite, or source environment
variables. If a VM already has `GITHUB_TOKEN`, Anthropic/OpenAI credentials, or
other server-provided env vars, this repo should not remove them.

## Adding Skills

Add Codex skills under:

```text
skills/codex/<skill-name>/SKILL.md
```

Add Claude skills under:

```text
skills/claude/<skill-name>/SKILL.md
```

Add Claude subagents under:

```text
agents/claude/<agent-name>.md
```

The install script copies these into the matching home directories without
deleting anything that was already present on the VM.

## Claude Plugins

`setup/install.sh` installs these Claude plugins when the `claude` CLI is
available:

- `sona-playwright@sona-marketplace`
- `code-reviewer@sona-marketplace`
- `doubledown@sona-marketplace`
- `spec@sona-marketplace`
- `caveman@caveman`

The marketplace sources are:

```bash
claude plugin marketplace add --scope user sona-is/marketplace
claude plugin marketplace add --scope user JuliusBrussee/caveman
```

Plugin install failures are non-fatal by default so a temporary marketplace or
network failure does not prevent the VM from starting. To make plugin install
failure block personalisation, set:

```bash
PERSONALISATION_PLUGIN_INSTALL_REQUIRED=true
```

## Codex Skills

This repo vendors selected Codex skills under `skills/codex/`, including
caveman, cavecrew, code-reviewer, hunk-review, log-flaky-test-from-failed-ci-run,
phoenix-liveview-socket-pattern, and sona-playwright. `cmux` is intentionally
not included.
