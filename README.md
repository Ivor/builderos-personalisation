# BuilderOS personalisation

Local personalisation repo for BuilderOS/FV VMs.

This repo follows the structure from the BuilderOS Platform Guide page
"Choosing and Customising the Agent". BuilderOS checks this repo out on each
new VM and applies `.builderos/personalisation.yaml` after the project checkout
and before the agent starts.

## What It Does

- Deep-merges safe Claude settings into `~/.claude/settings.json`.
- Deep-merges safe Codex settings into `~/.codex/config.toml`.
- Copies any repo-owned skills or agents from this repo into the VM user home.
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

Claude plugins and Codex skills are not enabled in config unless this repo also
installs the corresponding assets or the BuilderOS base image is known to
include them.

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
