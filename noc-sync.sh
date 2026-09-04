#!/usr/bin/env bash
# After editing a plugin, run this to sync to Noctalia sources + materialized
PLUGIN="$1"
if [ -z "$PLUGIN" ]; then
  echo "Usage: noc-sync <plugin-folder>"
  echo "Example: noc-sync today-reminders"
  exit 1
fi

SRC="/home/mindset/Projects/mindset-noctalia-plugins/$PLUGIN"
DST="$HOME/.local/state/noctalia/plugins/sources/Mindset/repo/$PLUGIN"
MAT="$HOME/.local/state/noctalia/plugins/materialized/Mindset/$PLUGIN"

if [ ! -d "$DST" ]; then
  echo "Plugin $PLUGIN not found in sources"
  exit 1
fi

rsync -a --delete "$SRC/" "$DST/" && echo "✓ synced to sources"
for f in panel.luau service.luau widget.luau; do
  [ -f "$DST/$f" ] && cp "$DST/$f" "$MAT/$f" 2>/dev/null && echo "✓ updated materialized/$f"
done
echo "Done. Wait ~2s for hot-reload."
