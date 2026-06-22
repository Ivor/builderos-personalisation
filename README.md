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
```

## Sona Preflight

`setup/sona-preflight.sh` is the pre-agent setup path for Sona VMs. It only runs
when it can find a checkout with both `docker-compose.yml` and
`backend/start-dev.sh`.

The script:

- starts the existing Compose backend path detached as `sona-dev`
- waits for the Phoenix startup log line
- creates only `sona_test` from `template0`
- compiles the test Mix environment with `MIX_ENV=test mix compile`

All Mix commands run inside the existing `sona-dev` container. They use
`env -u DISABLE_OBAN` so the test BEAM gets the normal test/runtime Oban queue
config while the dev server process keeps its original Compose environment.

Useful overrides:

```bash
SONA_PREFLIGHT_APP_TIMEOUT=900             # seconds to wait for Phoenix readiness
SONA_PREFLIGHT_COMPILE_TEST_ENV=false      # skip MIX_ENV=test compile
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
