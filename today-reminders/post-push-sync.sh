#!/usr/bin/env bash
# Auto-sync today-reminders after git push → sources + materialized
SRC="/home/mindset/Projects/mindset-noctalia-plugins/today-reminders"
DST="$HOME/.local/state/noctalia/plugins/sources/Mindset/repo/today-reminders"
MAT="$HOME/.local/state/noctalia/plugins/materialized/Mindset/today-reminders"

rsync -a --delete "$SRC/" "$DST/" 2>/dev/null && echo "✓ synced to sources" || { echo "rsync failed"; exit 1; }
for f in panel.luau service.luau widget.luau plugin.toml translations/; do
  [ -f "$DST/$f" ] && cp "$DST/$f" "$MAT/$f" 2>/dev/null && echo "✓ updated materialized/$f"
done
echo "Done. Close-open panel once to hot-reload."
