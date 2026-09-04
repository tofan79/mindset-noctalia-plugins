#!/usr/bin/env bash
# After editing a plugin, run this to sync to Noctalia sources + materialized.
#   noc-sync              — sync all plugins
#   noc-sync today-reminders  — sync one plugin

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DST_BASE="$HOME/.local/state/noctalia/plugins/sources/Mindset/repo"
MAT_BASE="$HOME/.local/state/noctalia/plugins/materialized/Mindset"

sync_plugin() {
  local plugin="$1"
  local src="$SCRIPT_DIR/$plugin"
  local dst="$DST_BASE/$plugin"
  local mat="$MAT_BASE/$plugin"

  if [ ! -d "$src" ]; then
    echo "⚠ $plugin: source not found, skipping"
    return
  fi
  if [ ! -d "$dst" ]; then
    echo "⚠ $plugin: not in sources, skipping (add to Noctalia first)"
    return
  fi

  rsync -a --delete "$src/" "$dst/" && echo "✓ $plugin → sources"
  rsync -a --delete "$dst/" "$mat/" && echo "✓ $plugin → materialized"
}

if [ -z "${1:-}" ]; then
  echo "Syncing all plugins..."
  for plugin in "$SCRIPT_DIR"/*/; do
    plugin="${plugin%/}"
    plugin="${plugin##*/}"
    sync_plugin "$plugin"
  done
  echo "Done. Wait ~2s for hot-reload."
else
  sync_plugin "$1"
  echo "Done. Wait ~2s for hot-reload."
fi
