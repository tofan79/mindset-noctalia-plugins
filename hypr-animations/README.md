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
directory, lists **every** `.lua` file with its display name, and highlights the
currently active one. All presets are rendered up front, so nothing waits on an
arrow key to appear. Type to filter, use Up/Down to move, and press Enter or
click a row to apply.

A preset's display name comes from the `name = "..."` line at the top of its
file; if the file has none, the file name (capitalised) is used.

Open the panel from a shell or a keybind:

```sh
noctalia msg panel-toggle mindset/hypr-animations:panel
```

Applying a preset calls `hyprctl eval` with the file's code after stripping `--`
comment lines. Lines are joined with real newlines (so keywords such as `then`
and `end` stay separate), and a small `hyde` shim is prepended for presets
ported from Hyde. The chosen file name is then written to `ANIMATION_PRESET` in
`animations.lua`, so the animation survives `hyprctl reload` and reboots.

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| `presets_dir` | `~/.config/hypr/config/animations_presets` | Directory scanned for `*.lua` animation presets. |
| `config_file` | `~/.config/hypr/config/animations.lua` | File whose `ANIMATION_PRESET` value is updated after a successful apply. |

## Notes

- `animations.lua` is authoritative on open; `current.txt` in the plugin data
  directory is only a fallback when that file cannot be read.
- A preset file whose `name = "..."` is missing, repeated, or empty simply
  falls back to its file name; there is no validation beyond that.
- The plugin edits only the `ANIMATION_PRESET = "..."` line (or the matching
  `require("config.animations_presets....")` call) in `config_file`. It never
  touches `hyprland.conf`.
- No network requests are made.

## License

MIT