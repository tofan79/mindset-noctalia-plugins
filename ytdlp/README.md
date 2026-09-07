# YT-DLP

Download media from any URL with yt-dlp right from the bar: search YouTube, pick
video/audio/quality, subtitles, SponsorBlock, queue, live progress, pause/resume
and history.

> Requires Noctalia v5 and plugin API 19.

## Plugin

| Field | Value |
| --- | --- |
| ID | `mindset/ytdlp` |
| Entries | Bar widget: `widget`; panel: `panel`; service: `service` |

## Requirements

- `yt-dlp` — the downloader itself
- `ffmpeg` — required for most downloads (merging, embedding, conversion)
- `wl-paste` — reading a URL straight from the clipboard

Each one is checked and reported if missing. The plugin never installs anything.

## Usage

| Gesture | Action |
| --- | --- |
| Left-click | Opens the panel. |

Paste a YouTube video, playlist, or any supported URL into the field and press
**Extract** to pull its metadata, or press **Download** to skip straight to
grabbing it. A bare `ytsearch:N` text runs a YouTube search and resolves to the
top result; a full search string such as `ytsearch10:lofi` works too.

### Playlists

When the extracted media is a playlist, the card shows one selectable chip per
item (up to 200, so a huge mix stays responsive). Selected items are joined with
`--playlist-items` on the download; **All** leaves it empty so yt-dlp downloads
the whole playlist by default, and **None** picks nothing.

### Queue

**Queue next** adds the current media to the queue and stays on the current
card, so you can line up several downloads and press **Run queue** (or let the
service drain it automatically). **Pause** / **Resume** and **Cancel** control
the running download. Live progress streams through the card with percent, size,
speed, and ETA.

### Last finished download

Once a download finishes its card is replaced by the next queued job, or by the
idle state — but the **Last finished download** strip stays at the top of the
scroll area, keeping **Copy path**, **Open folder**, and **Open file** available
even after the active card is overwritten. Dismiss it with the **x**.

### After download

The **After download** selector can copy the output path to the clipboard, open
the output folder, or open the finished file itself as soon as a download lands.

### SponsorBlock

Toggle **Skip sponsor segments** to remove sponsor/promo/intro/outro and other
segments. The chip row under it picks which categories are stripped, matching
what you'd set in yt-dlp's `--sponsorblock-remove`.

### Drive it from a keybind

```sh
noctalia msg panel-toggle mindset/ytdlp:panel
```

Suggested Hyprland keybind:

```lua
hl.bind(M .. " + ALT + D", hl.dsp.exec_cmd("noctalia msg panel-toggle mindset/ytdlp:panel"), { description = "YT-DLP panel" })
```

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| Bar icon | `brand-youtube-kids` | Glyph shown in the bar. |

The rest of the settings live in the panel and are stored per-plugin (a plugin
reads its settings but cannot write them, so the panel edits its own state file):

| Panel field | Description |
| --- | --- |
| Download directory | Where media lands. |
| Output template | yt-dlp `-o` template (e.g. `%(title)s.%(ext)s`). |
| Quality / Format / Track | Video resolution, container, and audio track. |
| Audio format / quality | Conversion target and bitrate. |
| Subtitle language | Subtitle fetches; **All** or a specific language. |
| Save / embed thumbnail | Writes a JPG and optionally embeds it. |
| Embed metadata | Writes title/artist tags. |
| Cookies from browser | Browser to read cookies from (`chrome`, `firefox`, …) or a profile / file path. |
| Proxy | SOCKS/HTTP proxy for the download. |
| Rate limit | e.g. `10M`. |
| Concurrent fragments | Parallel fragment count. |
| Extra yt-dlp arguments | Appended verbatim to the download command. |
| Skip downloaded media | `--download-archive` in the output dir. |
| Save history | Keep recent URLs for one-click refill. |
| Advanced | Toggle the advanced field group. |

## Architecture

| File | Role |
| --- | --- |
| `service.luau` | Owns every yt-dlp subprocess and all plugin state; reads `command` state writes. |
| `panel.luau` | Pure reader of `noctalia.state`; every control sends a command back to the service. |
| `widget.luau` | Bar glyph that reflects the active status. |

The service owns all state and all subprocesses. The panel and widget are pure
readers of `noctalia.state`; every interaction is a `command` write with a
monotonic nonce. Downloads stream live progress through `noctalia.runStream`,
with a small `sh` wrapper that records its pid (for pause/cancel) and echoes a
sentinel line so the service can read the exit code, since `runStream` has no
on-close callback.

Playlists are fetched with `--flat-playlist` to keep the extraction JSON small;
each item comes back as a lightweight index/id/title/duration stub that the
panel renders as a chip. Selected indices become `--playlist-items`.

## Tests

```sh
luajit ytdlp/tests/service_test.luau
```

Run from the `ytdlp` directory. 45 tests cover URL cleaning, info parsing,
progress parsing, download argument building, error mapping, and the command
flow.

## License

MIT
