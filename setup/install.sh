#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() {
  printf '[personalisation] %s\n' "$*"
}

sentinel_dir="${PERSONALISATION_STATE_DIR:-$HOME/.builderos-personalisation}"
sentinel_log="$sentinel_dir/install.log"

write_sentinel() {
  mkdir -p "$sentinel_dir"
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$sentinel_log"
}

log_step() {
  log "$*"
  write_sentinel "$*"
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

  log_step "warning: failed: $description"

  if [ "${PERSONALISATION_PLUGIN_INSTALL_REQUIRED:-false}" = "true" ]; then
    return 1
  fi

  return 0
}

install_claude_plugins() {
  if ! command -v claude >/dev/null 2>&1; then
    log_step "claude CLI not found; skipping Claude plugins"
    return 0
  fi

  log_step "adding Claude plugin marketplaces"
  try_step "add sona marketplace" claude plugin marketplace add --scope user sona-is/marketplace
  try_step "add caveman marketplace" claude plugin marketplace add --scope user JuliusBrussee/caveman

  log_step "installing Claude plugins"
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

install_codex_config_if_missing() {
  local src="$repo_root/config/codex/config.toml"
  local dst="$HOME/.codex/config.toml"

  if [ ! -f "$src" ] || [ -f "$dst" ]; then
    return 0
  fi

  log_step "installing Codex config fallback"
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
}

log_step "started from $repo_root"

log_step "installing repo-owned Codex skills"
copy_dir_contents "$repo_root/skills/codex" "$HOME/.codex/skills"

install_codex_config_if_missing

log_step "installing repo-owned Claude skills"
copy_dir_contents "$repo_root/skills/claude" "$HOME/.claude/skills"

log_step "installing repo-owned Claude agents"
copy_dir_contents "$repo_root/agents/claude" "$HOME/.claude/agents"

install_claude_plugins

log_step "done"
