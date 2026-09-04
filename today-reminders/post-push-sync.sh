#!/usr/bin/env bash
# Auto-sync today-reminders after git push
SRC="/home/mindset/Projects/mindset-noctalia-plugins/today-reminders"
DST="$HOME/.local/state/noctalia/plugins/sources/Mindset/repo/today-reminders"

rsync -a --delete "$SRC/" "$DST/" 2>/dev/null && echo "synced to sources" || echo "rsync failed, try manual update"
noctalia msg plugins update Mindset 2>/dev/null && echo "update queued" || true
