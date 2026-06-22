#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() {
  printf '[personalisation] %s\n' "$*"
}

copy_dir_contents() {
  local src="$1"
  local dst="$2"

  if [ ! -d "$src" ]; then
    return 0
  fi

  mkdir -p "$dst"

  find "$src" -mindepth 1 -maxdepth 1 ! -name ".gitkeep" -exec cp -R {} "$dst"/ \;
}

try_step() {
  local description="$1"
  shift

  if "$@"; then
    return 0
  fi

  log "warning: failed: $description"

  if [ "${PERSONALISATION_PLUGIN_INSTALL_REQUIRED:-false}" = "true" ]; then
    return 1
  fi

  return 0
}

install_claude_plugins() {
  if ! command -v claude >/dev/null 2>&1; then
    log "claude CLI not found; skipping Claude plugins"
    return 0
  fi

  log "adding Claude plugin marketplaces"
  try_step "add sona marketplace" claude plugin marketplace add --scope user sona-is/marketplace
  try_step "add caveman marketplace" claude plugin marketplace add --scope user JuliusBrussee/caveman

  log "installing Claude plugins"
  for plugin in \
    sona-playwright@sona-marketplace \
    code-reviewer@sona-marketplace \
    doubledown@sona-marketplace \
    spec@sona-marketplace \
    caveman@caveman
  do
    try_step "install $plugin" claude plugin install --scope user "$plugin"
  done
}

log "installing repo-owned Codex skills"
copy_dir_contents "$repo_root/skills/codex" "$HOME/.codex/skills"

log "installing repo-owned Claude skills"
copy_dir_contents "$repo_root/skills/claude" "$HOME/.claude/skills"

log "installing repo-owned Claude agents"
copy_dir_contents "$repo_root/agents/claude" "$HOME/.claude/agents"

install_claude_plugins

log "done"
