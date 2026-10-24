# 🚀 WrtBox — Native OpenWrt Manager (Winbox & DaRemote Style)

![Flutter](https://img.shields.io/badge/Flutter-3.27-02569B?logo=flutter)
![Platform](https://img.shields.io/badge/Platform-Android%20APK-3DDC84?logo=android)
![OpenWrt](https://img.shields.io/badge/Target-OpenWrt%20%2F%20LuCI-00B5E2?logo=openwrt)

**WrtBox** adalah aplikasi antarmuka *native* Android untuk mengelola router **OpenWrt** dengan konsep gabungan **Winbox (MikroTik)** dan **DaRemote**. Dirancang khusus agar pengguna OpenWrt (STB, Router, x86, maupun MikroTik CHR) dapat mengakses seluruh fitur asli Web Interface (LuCI) serta paket komunitas secara nyaman di layar HP tanpa perlu instalasi *agent* tambahan di router.

---

## ✨ Fitur Unggulan

### 🔌 1. Manajemen Multi-Device & Remote Jarak Jauh (Ala Winbox)
* **Saved Router Profiles:** Simpan banyak profil perangkat OpenWrt lengkap dengan IP, Port SSH, Port Web, Username, dan Password.
* **Dukungan Remote Lengkap:** Mendukung koneksi via **IP Lokal (LAN)**, **IP / MagicDNS Tailscale (`100.x.x.x`)**, **Domain Publik / DDNS / Cloudflare Zero Trust**, hingga mode **SSH Tunnel Only (Port-Forwarding)**.

### 📊 2. Status & Real-Time Monitoring (100% Auto-Detect)
* **Overview & Release RAM:** Pantau penggunaan RAM, CPU, suhu perangkat (*thermal*), sisa penyimpanan `/overlay`, daftar perangkat terhubung (*Active DHCP Leases*), serta tombol sekali klik **Release RAM** (`drop_caches`).
* **Live Logs & Process Manager:** Baca `logread` dengan filter kata kunci serta kelola/hentikan proses berjalan (`top` & *Kill PID*).
* **Traffic / Net Monitor:** Pantau total trafik **RX / TX** dan *packets* dari seluruh *interface* secara *real-time*.

### 🌐 3. Network Management (Deteksi Dinamis `ubus` & `uci`)
* **Tab Interfaces:** Deteksi otomatis seluruh *interface* yang ada di router (LAN, WAN, Tethering, WWAN, Bridge, dll.) lengkap dengan info *Protocol, Uptime, MAC, RX/TX, IPv4*, peringatan *Error: Network device is not present*, serta tombol **RESTART, STOP, EDIT, DELETE**, dan **ADD NEW INTERFACE**.
* **Tab Devices:** Deteksi semua perangkat fisik/virtual (`br-lan`, `eth0`, `wlan0`, `tap0`, dll.) beserta pengaturan cepat nilai **MTU**.
* **Tab Global Network Options:** Kelola *IPv6 ULA-Prefix*, *TCP/UDP Layer 3 Master Device (VRF)*, dan *Packet Steering* lengkap dengan tombol **SAVE & APPLY, SAVE,** dan **RESET**.

### ⚙️ 4. System, Startup & Scheduled Tasks (Cron)
* **Initscripts (`/etc/init.d/`):** Deteksi seluruh *service* berdasarkan urutan *Start priority* (`00` - `99`) lengkap dengan pencarian dan 5 tombol kontrol: **ENABLED / DISABLED, START, RESTART, RELOAD,** dan **STOP**.
* **Local Startup (`/etc/rc.local`):** Editor kode langsung untuk perintah *booting* dengan tombol **SAVE**.
* **Scheduled Tasks (`crontab`):** Deteksi otomatis jadwal Cron dengan fitur bantu **Tambah, Edit, Hapus Baris** serta penyimpanan kode langsung lewat tombol **SAVE**.
* **Power Control:** Eksekusi **Reboot** dan **Shutdown (`poweroff`)** langsung dari aplikasi.

### 📁 5. Root File Manager Penuh (Semua Direktori `/`)
* Akses bebas ke seluruh direktori mulai dari `/` (Root), `/etc/config`, `/etc/init.d`, `/root`, `/tmp`, hingga penyimpanan eksternal `/mnt`.
* **Built-in Code Editor:** Edit file konfigurasi atau *script* lengkap dengan fitur *Find & Replace* dan *backup* `.bak`.
* **Manajemen Izin File (CHMOD & CHOWN):** Pengaturan *permission* visual (*Owner, Group, Others* — R/W/X) maupun input kode oktal langsung (`0755`, `0644`, dll.) beserta opsi *Recursive (`-R`)*.
* **Operasi Lengkap:** *Rename*, *Copy/Cut/Paste*, *Delete*, *Extract/Compress* (`.tar.gz`, `.zip`), *Upload* file dari HP, dan **Instalasi langsung paket `.ipk`**.

### 💻 6. Terminal SSH Kelas JuiceSSH
* Mendukung **Multi-Session Tabs** (buka banyak sesi terminal sekaligus).
* **Extra Keys Bar (2 Baris):** Tombol *sticky* `CTRL` dan `ALT`, `ESC`, `TAB`, panah `↑` `↓` `←` `→`, `HOME`, `END`, `PGUP`, `PGDN`, `Ctrl+C`, `Ctrl+L`, serta simbol perintah Linux.
* **Snippets Manager:** Simpan dan jalankan perintah favorit dengan sekali ketuk.

### 🧩 7. Universal IPK Engine, VPN Cloudflared, Modem Hub & Speedtest
* **Satu Alat untuk Semua IPK (Menu Services):** Otomatis memindai seluruh `luci-app-*` yang terinstal dan membukanya melalui **Frameless Web-Bridge (Auto-Login)** maupun **Universal UCI Config Generator** tanpa perlu setting satu per satu.
* **VPN Cloudflare Zero Trust Tunnel (`cloudflared`):** Kelola *Tunnel Token*, *Protocol* (`auto`, `http2`, `quic`), *Edge IP*, *Region*, serta pantau *Live Log* tunnel.
* **Modem Hub (HiLink & Rakitan):** Simpan IP khusus modem (misal `192.168.8.1`), buka WebUI modem di *Tab Internal* (mendukung *SSH Local Port-Forwarding* saat diremote dari luar jaringan), dan kirim perintah **AT Command** (`atinout` / `sms_tool`).
* **Visual Speedtest:** Antarmuka speedometer visual di atas CLI (`ookla-speedtest`, `speedtest-cli`, `librespeed-cli`, atau *Cloudflare fallback*).

---

## 🛠️ Struktur Direktori Project

```text
├── .github/
│   └── workflows/
│       └── build-apk.yml               # Otomatisasi build APK via GitHub Actions
├── pubspec.yaml                        # Konfigurasi paket & dependencies Flutter
└── lib/
    ├── main.dart                       # Manajemen profil router & navigasi utama
    ├── models/
    │   └── router_profile.dart         # Model profil koneksi (LAN, Tailscale, Domain)
    ├── services/
    │   └── ssh_service.dart            # Mesin utama SSH, ubus, SFTP, & Port-Forwarding
    └── screens/
        ├── status_screen.dart          # Overview, Release RAM, Logs, Processes, NetMon
        ├── network_screen.dart         # Interfaces, Devices (MTU), Global Options
        ├── system_maintenance_screen.dart # Initscripts, rc.local, Cron, Reboot/Shutdown
        ├── file_manager_screen.dart    # Root File Manager (/), Editor, CHMOD, Upload
        ├── terminal_screen.dart        # Terminal PTY interaktif ala JuiceSSH
        └── tools_vpn_modem_screen.dart # Universal IPK Engine, Cloudflared, Modem, Speedtest
```

---

## 📦 Cara Build APK via GitHub Actions

1. *Fork* atau *Push* kode ini ke repositori GitHub kamu.
2. Buka tab **Actions** di repositori GitHub.
3. Pilih workflow **Build OpenWrt Manager APK**, lalu klik **Run workflow**.
4. Tunggu hingga proses *build* selesai (± 3 menit).
5. Unduh file APK siap instal pada bagian **Artifacts -> WrtBox-OpenWrt-Manager-APK**.
