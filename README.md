# Mindset Noctalia Plugins

Personal **[Noctalia](https://github.com/noctalia-dev/noctalia) v5** plugin source for
Hyprland sessions. Six plugins covering display, layout, animation, gaming, reminders,
and container management.

<p align="center">
  <img src="https://assets.noctalia.dev/noctalia-logo.svg?v=2" alt="Noctalia Logo" style="width: 128px" />
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT"></a>
  <img src="https://img.shields.io/badge/plugin%20API-13%E2%80%9319-ff69b4" alt="Plugin API 13–19">
  <img src="https://img.shields.io/badge/WM-Hyprland-7b68ee" alt="Hyprland">
</p>

## Plugins

| Plugin | API | Description |
| --- | --- | --- |
| `mindset/hypr-layouts` | 13 | Per-workspace tiling layout picker; auto-detects custom `lua:` layouts from `~/.config/hypr/layouts` on top of the four built-ins. |
| `mindset/hypr-animations` | 13 | Animation preset picker from `~/.config/hypr/config/animations_presets`. |
| `mindset/better-displays` | 19 | Per-monitor resolution, scale, position, transform, VRR and per-terminal font sizes. |
| `mindset/gamer-mode` | 19 | Live CPU/RAM/GPU metrics and one-click gamer mode. |
| `mindset/today-reminders` | 19 | Set a reminder for later today. Gets dismissed after it fires and never carries into tomorrow. |
| `mindset/better-workspaces` | 19 | Aesthetic workspace indicator with 12 display modes: Roman, Kanji, Arabic, Korean, Thai, Greek, Emoji, Russian, App Icon, and more. |
| `mindset/containers` | 19 | Docker and Podman status in the bar: containers, images, volumes, networks, and live stats, with start/stop/restart and removal controls. |

## Structure

```
mindset-noctalia-plugins/
├── catalog.toml           # index Noctalia reads for updates
├── README.md              # this file
├── better-displays/       # monitor & terminal font config
├── containers/            # Docker & Podman manager
├── gamer-mode/            # live metrics + gamer toggle
├── hypr-animations/      # animation preset picker
├── hypr-layouts/          # tiling layout picker
└── today-reminders/       # quick reminder from the bar
```

`plugin.toml` is authoritative for each plugin's id, entries, and settings;
`catalog.toml` is the index Noctalia reads for listing and updates.

## Install

### From GitHub (recommended)

```sh
noctalia msg plugins source add mindset git https://github.com/tofan79/mindset-noctalia-plugins.git
noctalia msg plugins enable mindset/hypr-layouts
noctalia msg plugins enable mindset/hypr-animations
noctalia msg plugins enable mindset/better-displays
noctalia msg plugins enable mindset/gamer-mode
noctalia msg plugins enable mindset/today-reminders
noctalia msg plugins enable mindset/containers
```

Noctalia fetches the source tag at startup, so plugins materialize from this
remote automatically after a reboot. `.luau` edits hot-reload; manifest changes
need a config reload.

## Development

Each plugin follows the Noctalia plugin API. Refer to the
[plugin development docs](https://docs.noctalia.dev/noctalia/plugins/development/):
[manifest](https://docs.noctalia.dev/noctalia/plugins/development/manifest/),
[entry types](https://docs.noctalia.dev/noctalia/plugins/development/entries/),
[declarative UI](https://docs.noctalia.dev/noctalia/plugins/development/declarative-ui/), and
[runtime API](https://docs.noctalia.dev/noctalia/plugins/development/runtime-api/).

Every plugin file starts with `--!nonstrict`.

## Releasing a new version

When you bump a plugin:

1. Bump `version` in `<plugin>/plugin.toml` (semver).
2. Bump `version` **and** `updated_at` for the same plugin in `catalog.toml` —
   both must stay in sync, or the Plugins/Updates UI shows a stale upgrade.
3. Update the plugin's `README.md` if behaviour changed.
4. Commit and push.
5. Verify with `noctalia msg plugins list | grep mindset` that the new version
   is listed.

## License

MIT. Each plugin keeps its own copyright; `plugin.toml` records the MIT license
per plugin.
