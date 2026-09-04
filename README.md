# Mindset Noctalia plugins

A personal **[Noctalia](https://github.com/noctalia-dev/noctalia) v5** plugin
source for Hyprland sessions. Each plugin lives in its own top-level directory
(the part of its id after the `/`) and installs through Noctalia's plugin
system.

<!-- markdownlint-disable-file MD033 -->
<p align="center">
  <img src="https://assets.noctalia.dev/noctalia-logo.svg?v=2" alt="Noctalia Logo" style="width: 128px" />
</p>

## Plugins

| Plugin | API | Description |
| --- | --- | --- |
| `mindset/hypr-layouts` | 13 | Per-workspace tiling layout picker; auto-detects custom `lua:` layouts from `~/.config/hypr/layouts` on top of the four built-ins. |
| `mindset/hypr-animations` | 13 | Animation preset picker from `~/.config/hypr/config/animations_presets`. |
| `mindset/better-displays` | 19 | Per-monitor resolution, scale, position, transform, VRR and per-terminal font sizes. |
| `mindset/gamer-mode` | 19 | Live CPU/RAM/GPU metrics and one-click gamer mode. |
| `mindset/today-reminders` | 19 | Set a reminder for later today. Gets dismissed after it fires and never carries into tomorrow. |
| `mindset/containers` | 19 | Docker and Podman status in the bar: containers, images, volumes, networks, and live stats, with start/stop/restart and removal controls. |

## Structure

```
mindset-noctalia-plugins/
  catalog.toml          # index of every plugin this source ships
  README.md             # this file
  better-displays/
    plugin.toml         # manifest: id, metadata, entries, settings
    widget.luau         # bar widget entry
    panel.luau          # panel entry
    bin/                # standalone omarchy backend scripts
    translations/en.json
    README.md
  gamer-mode/
    ...
  hypr-animations/
    ...
  hypr-layouts/
    ...
  today-reminders/
    ...
  containers/
    ...
```

`plugin.toml` is authoritative for each plugin's id, entries, and settings;
`catalog.toml` is the index Noctalia reads for listing and updates.

## Install

Add this checkout as a `path` source while developing, or use the GitHub URL on
a machine that has network access to it.

### Local checkout (development)

```sh
noctalia msg plugins source add mindset path /home/mindset/Projects/mindset-noctalia-plugins
noctalia msg plugins enable mindset/hypr-layouts
noctalia msg plugins enable mindset/hypr-animations
noctalia msg plugins enable mindset/better-displays
noctalia msg plugins enable mindset/gamer-mode
noctalia msg plugins enable mindset/today-reminders
noctalia msg plugins enable mindset/containers
```

### From GitHub

```sh
noctalia msg plugins source add mindset git https://github.com/tofan79/mindset-noctalia-plugins.git
noctalia msg plugins enable mindset/<plugin>
```

Noctalia fetches the source tag it tracks at startup, so after a reboot the
plugins materialize from this remote automatically. `.luau` edits hot-reload;
manifest changes are picked up on the next config reload.

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
5. Resync the materialized source: run Noctalia's startup fetch, or
   `git -C ~/.local/state/noctalia/plugins/sources/<author>/repo reset --hard origin/main`.
6. Verify with `noctalia msg plugins list | grep mindset` that the new version
   is listed.

## License

MIT. Each plugin keeps its own copyright; `plugin.toml` records the MIT license
per plugin.