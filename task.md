# LaraStack Installer Task Plan

## Prioritas Tinggi

- [x] Refactor `deploy-laravel.sh` agar mengikuti arsitektur 1 website = 1 Linux user.
  - [x] Jalankan `git pull` sebagai site user.
  - [x] Jalankan `composer install` sebagai site user.
  - [x] Jalankan `npm ci` dan `npm run build` sebagai site user.
  - [x] Jalankan semua `php artisan` sebagai site user.
  - [x] Auto-detect site user, PHP version, PHP-FPM pool, dan domain dari path/Nginx config.
  - [x] Tambahkan opsi `--seed`.
  - [x] Tambahkan opsi maintenance mode saat deploy.
  - [x] Restart PHP-FPM service dan Supervisor queue terkait.

- [x] Refactor `remove-laravel-site.sh` untuk model per-site user.
  - [x] Hapus Nginx server block.
  - [x] Hapus PHP-FPM pool per site user.
  - [x] Hapus Supervisor queue terkait.
  - [x] Opsi hapus folder project dengan konfirmasi eksplisit.
  - [x] Opsi hapus database dan database user dengan konfirmasi eksplisit.
  - [x] Opsi hapus Linux site user dengan konfirmasi eksplisit.
  - [x] Opsi hapus SSL certificate dengan konfirmasi eksplisit.

- [x] Refactor `create-supervisor-laravel-queue.sh`.
  - [x] Default user dari owner project, bukan `www-data`.
  - [x] Default path ke `/home/{site_user}/public_html`.
  - [x] Validasi versi PHP sesuai site.
  - [x] Buat log queue per site.

- [x] Tambahkan mode provisioning website kosong untuk handoff ke pengelola.
  - [x] Tambahkan opsi `--empty-site` atau `--handoff` di `create-laravel-site.sh`.
  - [x] Buat Linux site user, home, dan `/home/{site_user}/public_html`.
  - [x] Buat minimal `/home/{site_user}/public_html/public/index.html` sebagai placeholder.
  - [x] Tetap buat Nginx server block ke `/public`.
  - [x] Tetap buat PHP-FPM pool per site user.
  - [x] Tetap buat database dan user database jika diminta admin.
  - [x] Buat file handoff, misalnya `/home/{site_user}/site-info.env`, berisi APP_URL, path, PHP version, DB name/user/pass.
  - [x] Set permission file handoff agar hanya site user yang bisa baca.
  - [x] Integrasikan dengan `grant-site-ssh-access.sh` untuk memberi akses SSH pengelola.
  - [x] Dokumentasikan workflow admin membuat slot hosting kosong dan pengelola mengisi `public_html`.
  - [x] Sesuaikan `check-laravel-site.sh` agar website kosong tidak dianggap gagal fatal sebelum Laravel/artisan ada.

- [x] Tambahkan launcher global `larastack` dan `larastack-installer`.
  - [x] Buat menu utama yang menampilkan fitur tersedia.
  - [x] Buat subcommand untuk menjalankan script dari folder mana pun.
  - [x] Buat `install-larastack-command.sh` untuk symlink ke `/usr/local/bin`.
  - [x] Pasang command global otomatis setelah `install-laravel-server.sh`.
  - [x] Dokumentasikan cara menjalankan `larastack` dan `larastack-installer`.

## Prioritas Menengah

- [x] Buat `backup-laravel-site.sh`.
  - [x] Backup database.
  - [x] Backup `.env`.
  - [x] Backup `storage/app/public`.
  - [x] Backup Nginx config.
  - [x] Backup PHP-FPM pool.
  - [x] Simpan ke `/root/backups/laravel/{domain}/`.
  - [x] Tambahkan opsi `--domain=example.com` dan `--all`.

- [x] Buat `restore-laravel-site.sh`.
  - [x] Restore database.
  - [x] Restore `.env`.
  - [x] Restore uploaded files.
  - [x] Restore Nginx config dan PHP-FPM pool.
  - [x] Reload/restart service terkait.

- [x] Buat `check-laravel-site.sh`.
  - [x] Cek Nginx config.
  - [x] Cek PHP-FPM pool dan socket.
  - [x] Cek permission project.
  - [x] Cek `.env`.
  - [x] Cek koneksi database via Artisan.
  - [x] Cek queue status.
  - [x] Cek SSL expiry.
  - [x] Cek HTTP response domain.

- [x] Tambahkan output JSON ke `list-laravel-sites.sh`.
  - [x] Opsi `--json`.
  - [x] Hindari menampilkan password atau secret.
  - [x] Pastikan output bisa dipakai dashboard/monitoring.

- [x] Tambahkan manajemen akses SSH pengelola website.
  - [x] Buat `grant-site-ssh-access.sh`.
  - [x] Auto-detect site user dari domain/Nginx config.
  - [x] Input public key pengelola website secara interaktif.
  - [x] Tambahkan key ke `/home/{site_user}/.ssh/authorized_keys`.
  - [x] Set permission `.ssh` dan `authorized_keys` otomatis.
  - [x] Tampilkan command login `ssh {site_user}@server`.
  - [x] Pastikan user pengelola tidak punya akses `sudo` secara default.
  - [x] Buat `revoke-site-ssh-access.sh` untuk mencabut key.
  - [x] Hardening permission `.env` agar tidak terbaca user website lain.
  - [x] Dokumentasikan alur admin memberi akses ke pengelola.

## Prioritas Rendah

- [x] Buat `set-laravel-env.sh`.
  - [x] Set key/value `.env` dengan backup otomatis.
  - [x] Jalankan sebagai root tetapi file tetap milik site user.
  - [x] Opsi clear/cache config setelah update.

- [x] Improve `install-laravel-server.sh`.
  - [x] Pilihan PHP default 8.3 atau 8.4.
  - [x] Validasi Node.js 24 aktif.
  - [x] Tampilkan health summary service setelah install.
  - [x] Tampilkan next-step command setelah install selesai.

- [x] Tambahkan rollback deploy.
  - [x] Simpan commit sebelum deploy.
  - [x] Jika composer/npm/artisan gagal, tampilkan command rollback.
  - [x] Opsi rollback otomatis untuk Git checkout.
  - [x] Jangan rollback migration otomatis kecuali diminta eksplisit.
