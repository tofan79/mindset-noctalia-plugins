# Better Workspaces

Aesthetic workspace indicator for Noctalia — replaces the default workspace widget
with beautiful display modes.

## Plugin

| Field | Value |
| --- | --- |
| ID | `mindset/better-workspaces` |
| Entries | Bar widget: `widget`; panel: `panel` |

## Display Modes

| Mode | Example | Description |
| --- | --- | --- |
| Default | `1, 2, 3` | Standard numbers |
| Roman | `I, II, III` | Classical Roman numerals |
| Kanji | `一, 二, 三` | Japanese/Chinese characters |
| Arabic | `١, ٢, ٣` | Eastern Arabic numerals |
| Korean | `ㄱ, ㄴ, ㄷ` | Korean consonants |
| Thai | `๑, ๒, ๓` | Thai numerals |
| Greek | `α, β, γ` | Greek alphabet |
| Hindi | `१, २, ३` | Devanagari numerals |
| Emoji | `①, ②, ③` | Circled numbers |
| Russian | `а, б, в` | Cyrillic alphabet |
| App Icon | `🪟` | Window icon when occupied |
| App Name | `1 📱` | Number with icon |

## Usage

| Gesture | Action |
| --- | --- |
| Left-click | Opens the panel |
| Keyboard (panel) | Up/Down to navigate, Enter to switch, Esc to close |

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| Display Mode | `default` | How numbers are shown |
| Workspace Count | `9` | How many workspaces to show (1-20) |
| Reveal Occupied | `true` | Show workspaces beyond count while they exist |
| Dim Empty | `true` | Fade workspaces with no windows |

## Architecture

| File | Role |
| --- | --- |
| `widget.luau` | Bar widget showing current workspace |
| `panel.luau` | Full workspace list + settings |
| `translations/en.json` | Display mode labels |

## License

MIT
