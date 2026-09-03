# Personal Noctalia plugin source
Sumber plugin pribadi untuk Noctalia v5. Tambahkan sebagai source, lalu aktifkan plugin yang diinginkan.

```sh
noctalia msg plugins source add mindset path /home/mindset/Projects/mindset-noctalia-plugins
noctalia msg plugins enable mindset/better-displays
```

## Plugins

| Plugin | Description |
|--------|-------------|
| `mindset/better-displays` | Per-monitor resolution, scale, position, transform and terminal font sizes |
| `mindset/gamer-mode` | Live CPU/RAM/GPU metrics and one-click gamer mode |
| `mindset/hypr-animations` | Animation preset picker |
| `mindset/hypr-layouts` | Tiling layout picker |

## Release checklist

Saat rilis versi baru salah satu plugin, ikuti langkah ini:

1. Bump `version` di `<plugin>/plugin.toml`.
2. Bump `version` (dan `updated_at`) entri plugin yang sama di `catalog.toml` — wajib, keduanya harus sinkron. Tanpa ini UI Plugins & Update menampilkan "update to <versi lama>" karena membandingkan plugin ter-materialisasi vs versi di catalog.
3. Update `README.md` plugin bila perilaku berubah.
4. Commit & push.
5. Sinkronkan source repo Noctalia: `git -C ~/.local/state/noctalia/plugins/sources/<author>/repo reset --hard origin/main`.
6. Verifikasi: `noctalia msg plugins list | grep <plugin>` menampilkan versi baru.
