#!/usr/bin/env bash
# After git push, sync to Noctalia sources + materialized
PLUGIN="$1"
if [ -z "$PLUGIN" ]; then
  echo "Usage: ./noc-sync.sh <plugin-folder-name>"
  echo "Examples:"
  echo "  ./noc-sync.sh today-reminders"
  exit 1
fi

SRC="/home/mindset/Projects/mindset-noctalia-plugins/$PLUGIN"
DST="$HOME/.local/state/noctalia/plugins/sources/Mindset/repo/$PLUGIN"
MAT="$HOME/.local/state/noctalia/plugins/materialized/Mindset/$PLUGIN"

if [ ! -d "$DST" ]; then
  echo "Plugin $PLUGIN not found in sources, skipping"
  exit 0
fi

rsync -a --delete "$SRC/" "$DST/" && echo "✓ synced $PLUGIN → sources"
for f in panel.luau service.luau widget.luau; do
  [ -f "$DST/$f" ] && cp "$DST/$f" "$MAT/$f" && echo "✓ updated materialized/$f"
done
echo "Done. Restart plugin with: noctalia msg plugins disable $PLUGIN && sleep 1 && noctalia msg plugins enable $PLUGIN"
