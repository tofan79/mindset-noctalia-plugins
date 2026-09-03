# Hypr Animations

Pick an animation preset from your Hyprland config and apply it live, without
reloading the desktop. Lists every `*.lua` file in the animations directory,
shows the preset name from its `name = "..."` line, and applies the chosen file
exactly like the switch-animations script.

Replaces the rofi animation picker.

> Requires Noctalia v5, plugin API 13, and a Hyprland session.

## Plugin

| Field | Value |
| --- | --- |
| ID | `mindset/hypr-animations` |
| Entries | Bar widget: `toggle`; panel: `panel` |

## Requirements

- `hyprctl` (Hyprland) to apply each preset.

The plugin applies a preset by evaluating its code through `hyprctl eval` — the
same command the shell's switch-animations script uses.

## Usage

Click the palette glyph in the bar to open the panel. It scans the animation
directory, lists every `.lua` file with its display name, and highlights the
currently active one. Type to filter, use Up/Down to move, and press Enter or
click a row to apply.

A preset's display name comes from the `name = "..."` line at the top of its
file; if the file has none, the file name is used.

Open the panel from a shell or a keybind:

```sh
noctalia msg panel-toggle mindset/hypr-animations:panel
```

Applying a preset calls `hyprctl eval` with the file's code after stripping `--`
comment lines, so the animations take effect immediately and are not persisted
into your static config.

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| `presets_dir` | `~/.config/hypr/animations` | Directory scanned for `*.lua` animation presets. |

## Notes

- The active preset file name is cached in `current.txt` in Noctalia's plugin
  data directory so the panel can highlight it across restarts.
- A preset file whose `name = "..."` is missing, repeated, or empty simply
  falls back to its file name; there is no validation beyond that.
- Nothing edits your `hyprland.conf`. The plugin only evaluates the chosen
  animation code at runtime.
- No network requests are made.

## License

MIT