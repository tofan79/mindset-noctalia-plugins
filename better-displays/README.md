# Better Displays

Per-monitor resolution, scale, position, transform and per-terminal font sizes from the bar.

Port of [nightdevil00/better-displays](https://github.com/nightdevil00/better-displays) to Noctalia v5 (Luau).

## Features

- Monitor selector (multi-monitor support)
- Resolution picker (dropdown from available modes)
- Scale presets (1x, 1.25x, 1.6x, 2x, 3x, 4x)
- Position controls (auto + relative positioning to other monitors)
- Orientation (0°, 90°, 180°, 270°)
- Terminal font size controls (alacritty, kitty, ghostty, foot)

## Dependencies

- `hyprctl` (Hyprland)
- `jq`

## Install

Copy to your Noctalia plugins directory:

```bash
cp -r better-displays ~/.local/share/noctalia/plugins/
```

Enable in Noctalia:

```bash
noctalia msg plugins enable mindset/better-displays
```

## Usage

Click the monitor icon in the bar to open the display settings panel.

## License

MIT
