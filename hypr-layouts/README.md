# Hypr Layouts

Pick the tiling layout of the active Hyprland workspace from a centered,
keyboard-first panel. Each workspace keeps its own layout, so Dock-style,
Dwindle, Master, and the rest can co-exist.

Replaces the rofi layout picker.

> Requires Noctalia v5, plugin API 13, and a Hyprland session.

## Plugin

| Field | Value |
| --- | --- |
| ID | `mindset/hypr-layouts` |
| Entries | Service: `poller`; bar widget: `toggle`; panel: `panel` |

## Requirements

- `hyprctl` (Hyprland) reads the active workspace and applies a layout.

The panel and the service both read state through `hyprctl activeworkspace`,
and applying a layout goes through `hyprctl eval`.

## Usage

Click the layout glyph in the bar to open the panel for the **currently focused
workspace**. The panel shows the six supported layouts:

| Layout | Value |
| --- | --- |
| Deck Stack | `lua:deck` |
| Dwindle | `dwindle` |
| Fair Grid | `lua:fair` |
| Master | `master` |
| Monocle | `monocle` |
| Scrolling | `scrolling` |

Type to filter, use Up/Down to move the selection, and press Enter or click a
row to apply. The chosen layout is scoped to the current workspace id, so a
different workspace can keep a different layout.

The active layout is highlighted. After a reboot, the mark follows what this
plugin last applied (see **Notes**).

Open the panel from a shell or a keybind:

```sh
noctalia msg panel-toggle mindset/hypr-layouts:panel
```

The bar widget tracks the active workspace through the service and shows the
current layout. Clicking it re-opens the panel for the focused workspace.

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| No settings | — | The plugin has no user-facing settings. |

## IPC

The `poller` service publishes the active workspace layout to
`hypr_layouts_state` every second, which drives the bar widget. There are no
user-facing actions beyond opening the panel.

## Notes

- Applying a layout writes it to a `layouts.json` map in Noctalia's plugin data
  directory. Hyprland's `tiledLayout` reports a wrong value for `lua:` layouts
  (a loaded Deck reports as "fair"), so the panel's active mark follows what it
  last applied instead of `hyprctl`.
- Only one layout is exposed per workspace, set the moment you pick it, so there
  is no per-workspace layout list to edit afterwards.
- The panel makes a `hyprctl eval` call per apply and closes itself on success.
- No files are written outside Noctalia's plugin data directory and no network
  requests are made.

## License

MIT