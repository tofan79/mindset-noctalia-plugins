# Hypr Layouts

Pick the Hyprland tiling layout from a centered, keyboard-first panel. The
choice is applied immediately and written back to `misc.lua`, so it survives a
Hyprland config reload or reboot instead of snapping back to the default
`scrolling` layout.

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

Click the layout glyph in the bar to open the panel. The highlighted row comes
from `hyprctl getoption general:layout`, not from a cached per-workspace guess.

The **four built-in Hyprland layouts** are always listed:

| Layout | Value |
| --- | --- |
| Dwindle | `dwindle` |
| Master | `master` |
| Monocle | `monocle` |
| Scrolling | `scrolling` |

On top of those, the panel **auto-detects** any custom layout registered from
files in the layouts folder — including your own `hl.layout.register` layout
modules such as Deck and Fair:

| Layout | Value |
| --- | --- |
| Deck Stack | `lua:deck` |
| Fair Grid | `lua:fair` |

Add a new `*.lua` file that calls `hl.layout.register("name", …)` in the
layouts folder and it appears automatically on the next open; no code change
needed. Built-ins always stay on top, duplicates are skipped.

Type to filter, use Up/Down to move the selection, and press Enter or click a
row to apply. The chosen layout becomes the session-wide default and is saved
into `misc.lua`, so all workspaces stay consistent after a reload or reboot.

The active layout is highlighted from the live `general:layout` option.

Open the panel from a shell or a keybind:

```sh
noctalia msg panel-toggle mindset/hypr-layouts:panel
```

The bar widget tracks `general:layout` through the service and shows the
current layout. Clicking it re-opens the panel.

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| `layouts_dir` | `~/.config/hypr/layouts` | Folder scanned for custom `*.lua` layout modules. Set it where your `hl.layout.register` files live. |
| `config_file` | `~/.config/hypr/config/misc.lua` | File whose `general.layout` value is updated after a successful apply. |

## IPC

The `poller` service publishes `hyprctl getoption general:layout -j` to
`hypr_layouts_state` every second, which drives the bar widget. There are no
user-facing actions beyond opening the panel.

## Notes

- Applying a layout updates the `general.layout` value in `config_file` and
  applies the same value live with `hyprctl eval`. A runtime-only
  `hl.workspace_rule` was lost on reload and made the layout snap back to
  `scrolling`, so it is no longer used.
- The layout is session-wide. All workspaces stay on the chosen layout, which is
  the stable behaviour on a single-monitor Hyprland setup.
- The panel makes a `hyprctl eval` call per apply and closes itself on success.
- No files are written outside the configured Hyprland config file and no
  network requests are made.

## License

MIT