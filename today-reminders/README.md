# Today Reminders

Set a reminder for later today. Gets dismissed after it fires and never carries
into tomorrow.

> Requires Noctalia v5 and plugin API 19.

## Plugin

| Field | Value |
| --- | --- |
| ID | `mindset/today-reminders` |
| Entries | Bar widget: `reminders`; panel: `main`; service: `service` |

## Usage

| Gesture | Action |
| --- | --- |
| Left-click | Opens the panel. |
| Right-click | — |

The widget shows the bell glyph. `show_count` adds the pending count.

The panel has two fields:

- **Minutes** — how many minutes from now to fire (e.g. `5`, `30`, `120`).
- **Text** — optional note shown when the reminder fires (displayed by
  `notify-send`).

### Quick-add

When the list is empty, clicking **+** adds the reminder and closes the panel
immediately — one click, no friction. When reminders already exist the panel
stays open so you can add more.

Reopen the panel from the bar widget or a keybind:

```sh
noctalia msg panel-toggle mindset/today-reminders:main
```

Suggested Hyprland keybind:

```lua
hl.bind(M .. " + ALT + R", hl.dsp.exec_cmd("noctalia msg panel-toggle mindset/today-reminders:main"), { description = "Today Reminders panel" })
```

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| Glyph | `bell-ringing` | Glyph shown in the bar. |
| Show count | `true` | Appends the pending reminder count to the widget. |
| Sound | `true` | Plays a sound when the reminder fires. |

## Architecture

| File | Role |
| --- | --- |
| `service.luau` | Reads `reminders_cmd` state, manages the reminder list, fires `notify-send` on time. |
| `panel.luau` | Minutes + text input and reminder list. |
| `widget.luau` | Bar glyph with optional count. |

Reminders are kept in `noctalia.state` only — no files on disk. Each fire time
is compared against `os.time()` on every tick. A reminder that reaches its time
fires via `notify-send`, gets marked `done`, and is kept in the list until the
next Noctalia startup (so you can see it was dismissed). New day = fresh list.

## License

MIT
