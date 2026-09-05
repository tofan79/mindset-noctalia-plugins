# Better Displays

Per-monitor resolution, scale, position, and orientation from a single
centered panel, plus independent font sizes for each detected terminal
emulator. Settings apply live and are persisted so they survive a reboot.

Replaces scrolling through `hyprctl` by hand for everyday display tweaks.

Port of [nightdevil00/better-displays](https://github.com/nightdevil00/better-displays) to Noctalia v5 (Luau).

> Requires Noctalia v5, plugin API 13, and a Hyprland session.

## Plugin

| Field | Value |
| --- | --- |
| ID | `mindset/better-displays` |
| Entries | Bar widget: `toggle`; panel: `panel` |

## Requirements

- `hyprctl` (Hyprland) reads monitors and applies changes live.
- `jq` reads and rewrites the persisted state.

The bar widget shows a `screen-share` glyph when more than one monitor is
attached and a `device-desktop` glyph otherwise.

## Usage

Click the monitor glyph in the bar to open the panel. Select a monitor at the
top, then adjust any of:

- **Resolution** — a dropdown of every mode the monitor advertises.
- **Scale** — 1x, 1.25x, 1.6x, 2x, 3x, 4x.
- **Position** — an `auto` button plus one button per other monitor for Left,
  Right, Above, and Below.
- **Orientation** — 0°, 90°, 180°, 270°.
- **VRR** — Off, On, Fullscreen, Fullscreen+video.
- **Terminal font size** — a minus/plus pair per detected terminal.

Open the panel from a shell or a keybind:

```sh
noctalia msg panel-toggle mindset/better-displays:panel
```

### VRR values

Hyprland's per-monitor `vrr` takes four values, and the panel mirrors them:

| Value | Meaning |
| --- | --- |
| `0` | Off |
| `1` | On |
| `2` | Fullscreen only |
| `3` | Fullscreen + video/game media |

The panel reads the current VRR from the persisted state per monitor. Changing
any other setting (scale, position, orientation) keeps your VRR untouched
instead of resetting it.

### Applying and persisting

Each change is applied immediately with `hyprctl eval` and written both to the
runtime state (`~/.local/state/noctalia/plugins/data/mindset/better-displays/displays.json`) and, when Hyprland config
uses `hl.monitor(...)` lines, to your active `monitors.lua`. That is what makes
the layout survive a reboot.

The plugin locates `monitors.lua` automatically, in this order:
`HYPRLAND_CONFIG_FILE`, `HYPR_CONFIG_DIR`, then a search of the common
Hyprland locations. If your file lives elsewhere (or you run a non-Lua
`hyprland.conf`), set `monitorsLua` below to point at it explicitly.

### Terminal font sizes

Only the four supported terminals can be edited: **alacritty**, **kitty**,
**ghostty**, and **foot**. Every other installed terminal appears in the list
read-only. Sizes are clamped to 6–40 points and written straight into each
terminal's config file; kitty and ghostty are signalled to re-read their config
so the change shows immediately.

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| `monitorsLua` | *(empty)* | Absolute path to your Hyprland `monitors.lua`. Empty uses auto-detection. |

Set `monitorsLua` only when auto-detection misses your file. A non-empty value
is passed to the backend for every apply.

## IPC

The panel exposes no entry actions beyond opening it. The `toggle` widget
either opens the panel or toggles nothing — it only opens (`noctalia.togglePanel`).

## Notes

- The backend scripts live in the plugin's `bin/` directory and are also usable
  standalone from a shell:
  `better-display-monitor list | set <output> [--mode WxH@Hz] [--scale N] [--pos X,Y] [--transform N] [--vrr 0-3]`
  and `better-display-terminal list | set <term> <size> | set-all <size>`.
- Scale is snapped to whole logical pixels (1/120 steps), mirroring Hyprland's
  constraint, so a requested scale may round to the nearest valid value.
- The full panel renders inside a scroll area, so a large monitor list or many
  terminals never overflows the panel height.
- Files written: `~/.local/state/noctalia/plugins/data/mindset/better-displays/displays.json`, the selected `monitors.lua`,
  and the config of any terminal you adjust. No network requests are made.

## License

MIT