# Personal Noctalia plugin source
Sumber plugin pribadi untuk Noctalia v5. Tambahkan sebagai source, lalu aktifkan plugin yang diinginkan.

```sh
noctalia msg plugins source add mindset path /home/mindset/Projects/mindset-noctalia-plugins
noctalia msg plugins enable mindset/hotspot
```

## Release checklist

Saat rilis versi baru salah satu plugin, ikuti langkah ini:

1. Bump `version` di `<plugin>/plugin.toml`.
2. Bump `version` (dan `updated_at`) entri plugin yang sama di `catalog.toml` — wajib, keduanya harus sinkron. Tanpa ini UI Plugins & Update menampilkan "update to <versi lama>" karena membandingkan plugin ter-materialisasi vs versi di catalog.
3. Update `README.md` plugin bila perilaku berubah.
4. Commit & push.
5. Sinkronkan source repo Noctalia: `git -C ~/.local/state/noctalia/plugins/sources/<author>/repo reset --hard origin/main`.
6. Verifikasi: `noctalia msg plugins list | grep <plugin>` menampilkan versi baru.

## hotspot — Wi-Fi Hotspot (Concurrent)

Toggle hotspot WiFi tanpa memutus koneksi WiFi utama (cara kerja ala Windows): membuat
interface virtual `ap0` pada phy yang sama dengan WiFi aktif, lalu menjalankan AP pada
channel yang sama. Operasi root (iw/nmcli) dilakukan via `pkexec` — password diminta lewat
panel polkit Noctalia.

- Start/stop dari widget bar (klik = panel, klik kanan = toggle, tengah = refresh)
- Daftar perangkat terhubung (station dump via helper)
- SSID & password diatur di Settings → Plugins → hotspot
