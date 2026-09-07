# Containers

Docker and Podman status in the bar: containers, images, volumes, networks, and
live stats, with start/stop/restart and removal controls.

> Requires Noctalia v5 and plugin API 19.

## Plugin

| Field | Value |
| --- | --- |
| ID | `mindset/containers` |
| Entries | Bar widget: `containers`; panel: `main`; service: `service` |

## Requirements

- `docker` or `podman` (the `engine` setting picks which; `auto` uses whichever is available)

## Usage

| Gesture | Action |
| --- | --- |
| Left-click | Opens the panel. |

The widget shows a container glyph with the running container count when
**Show running count** is on.

The panel is organised into tabs — **Containers**, **Images**, **Volumes**, and
**Networks** — plus a **Hardware** / resources view with live per-container
stats. The search field filters the current list, and the filter row narrows
containers to **All**, **Running**, or **Stopped**.

Per container you can **Start**, **Stop**, **Restart**, and **Remove**. Images,
volumes, and networks can be removed too. Multi-select controls let you act on
several at once.

Toggle the panel from a keybind:

```sh
noctalia msg panel-toggle mindset/containers:main
```

Suggested Hyprland keybind:

```lua
hl.bind(M .. " + ALT + C", hl.dsp.exec_cmd("noctalia msg panel-toggle mindset/containers:main"), { description = "Containers panel" })
```

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| Engine | `auto` | `docker`, `podman`, or auto-detect whichever is installed. |
| Refresh interval | `5` | Seconds between status refreshes: 3, 5, 10, 15, or 30. |
| Bar icon | `brand-docker` | Glyph shown in the bar. |
| Show running count | On | Appends the running container count to the widget. |

## Architecture

| File | Role |
| --- | --- |
| `service.luau` | Runs `docker`/`podman` subprocesses, collects status and stats, publishes state. |
| `panel.luau` | Pure reader of `noctalia.state`; tabbed management UI. |
| `widget.luau` | Bar glyph with the running container count. |

Like the rest of the source, the service owns all state and subprocesses. Every
management action (start/stop/restart/remove) is dispatched as a command and run
with safely quoted arguments — `docker` argument arrays are joined back into one
shell-quoted command line so no user or container-derived text can be
interpolated into the command.

## License

MIT
