# Personal Noctalia plugin source
Sumber plugin pribadi untuk Noctalia v5. Tambahkan sebagai source, lalu aktifkan plugin yang diinginkan.

```sh
noctalia msg plugins source add mindset path /home/mindset/Projects/mindset-noctalia-plugins
noctalia msg plugins enable mindset/hotspot
```

## hotspot — Wi-Fi Hotspot (Concurrent)

Toggle hotspot WiFi tanpa memutus koneksi WiFi utama (cara kerja ala Windows): membuat
interface virtual `ap0` pada phy yang sama dengan WiFi aktif, lalu menjalankan AP pada
channel yang sama. Operasi root (iw/nmcli) dilakukan via `pkexec` — password diminta lewat
panel polkit Noctalia.

- Start/stop dari widget bar (klik = panel, klik kanan = toggle, tengah = refresh)
- Daftar perangkat terhubung (station dump via helper)
- SSID & password diatur di Settings → Plugins → hotspot
