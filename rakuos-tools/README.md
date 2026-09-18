# RakuOS Tools

Check and apply RakuOS updates without the software center: container image
(`bootc`), overlay packages (`rum`), Flatpak, rollback, overlay reset, kernel
args, zram and image switch — all headless via `sudo-rs` + a baked NOPASSWD
sudoers drop-in (no `pkexec` dialogs).

- **id:** `mindset/rakuos-tools`
- **version:** 0.1.1 · **plugin_api:** 19 (like the other `mindset` plugins)
- **requires:** Noctalia v5, `rum`, `bootc`, `sudo-rs`, `notify-send`

## Features

- **Service (`checker`)** — periodic check of `bootc status --json` +
  `bootc upgrade --check` + `rum check-upgrade --json`; publishes everything to
  `noctalia.state["rakuos_updates"]`.
- **Bar widget (`indicator`)** — badge with the number of available updates,
  spinner while checking, tooltip with image/package summary. Click closes and
  opens the panel.
- **Control-center shortcut (`update`)** — tile showing update state; click
  opens the panel.
- **Panel (`main`)** — Status + actions:
  - Check now, Update packages (`rum upgrade -y`), Update image
    (`rakuos-bootc-upgrade.service` = `bootc upgrade` + `fc-cache` +
    `sync-grub-theme`), Flatpak update.
  - Rollback (`bootc rollback` + `rakuos-reset-overlay --soft`, two-step
    confirm) and overlay reset (`rakuos-reset-overlay --soft`).
  - Advanced: switch image (`bootc switch`), zram size
    (`tee /etc/systemd/zram-generator.conf`), kernel args
    (`tee /usr/lib/bootc/kargs.d/*.toml`; applies on the next image update —
    `bootc kargs` does not exist on bootc 1.16.10).
  - Live output log for long-running upgrades (`noctalia.runStream`).

## Install

```sh
noctalia msg plugins source add mindset git https://github.com/tofan79/mindset-noctalia-plugins.git
noctalia msg plugins update mindset
noctalia msg plugins enable mindset/rakuos-tools
```

## Usage

- Open the panel: `noctalia msg panel-toggle mindset/rakuos-tools:main`
  (or click the bar badge).
- Force a check: `noctalia msg plugin mindset/rakuos-tools:checker all check`.

Notifications are sent at most once per new set of available updates; the
signature is persisted in `pluginDataDir("notify_signature.txt")`.

## Settings

- `glyph` — bar glyph when everything is up to date.
- `show_badge` — show the update count next to the glyph.
- `check_interval` — automatic check schedule: `6h`, `12h`, `1d` (10:00 AM),
  `1w` (10:00 AM), or `manual` (only via the panel "Check now" button).
- `check_packages` — also run `rum check-upgrade` each cycle.
- `notify_on_updates` — desktop notification on new updates.

## Auth / sudoers

All commands run through `sudo`, backed by the image-baked drop-in
`/etc/sudoers.d/rakuos-plugin-updates` (`system_files/etc/sudoers.d/` in the
`hyprland-rakuos` image repo):

```sudoers
%wheel ALL=(ALL) NOPASSWD: /usr/libexec/rakuos/rakuos-reset-overlay --soft
%wheel ALL=(ALL) NOPASSWD: /usr/libexec/rakuos/rakuos-reset-overlay --confirm
%wheel ALL=(ALL) NOPASSWD: /usr/bin/flatpak update -y
%wheel ALL=(ALL) NOPASSWD: /usr/bin/rum config-manager --set-enabled *
%wheel ALL=(ALL) NOPASSWD: /usr/bin/rum config-manager --set-disabled *
%wheel ALL=(ALL) NOPASSWD: /usr/bin/rum copr enable *
%wheel ALL=(ALL) NOPASSWD: /usr/bin/dnf5 config-manager addrepo *
%wheel ALL=(ALL) NOPASSWD: /usr/bin/tee /etc/systemd/zram-generator.conf
%wheel ALL=(ALL) NOPASSWD: /usr/bin/tee /usr/lib/bootc/kargs.d/*.toml
```

`bootc`, `rum` and `systemctl start rakuos-bootc-upgrade.service` are already
NOPASSWD from the base image. Until a freshly built image (with this drop-in) is
deployed and rebooted, only the check commands work headless.

## Development

- Local dev override: `~/.local/share/noctalia/plugins/mindset/rakuos-tools/`
  (edit → hot-reload).
- Lint: `noctalia plugins lint <plugin-dir>`.
- The command set mirrors `rakuos-software`'s update backend
  (`crates/backend/updates/src/lib.rs`).