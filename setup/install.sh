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

log "installing repo-owned Codex skills"
copy_dir_contents "$repo_root/skills/codex" "$HOME/.codex/skills"

log "installing repo-owned Claude skills"
copy_dir_contents "$repo_root/skills/claude" "$HOME/.claude/skills"

log "installing repo-owned Claude agents"
copy_dir_contents "$repo_root/agents/claude" "$HOME/.claude/agents"

log "done"
