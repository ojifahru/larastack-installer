# Laravel Production Server Scripts

Paket ini menyiapkan stack Laravel production tanpa aaPanel untuk Ubuntu 24.04:

- Nginx dari apt
- PHP-FPM 8.3 default
- opsi PHP 8.4 jika tersedia dari repository apt yang sudah terkonfigurasi
- MariaDB
- Redis
- Supervisor
- Composer
- Node.js 24 dari NodeSource apt repository
- Certbot untuk Let's Encrypt
- UFW firewall
- struktur multi-website per Linux user di `/home/{site_user}/public_html`
- PHP-FPM pool terpisah per website
- Git, Composer, NPM, dan Artisan dijalankan sebagai user website

## File Script

- `install-laravel-server.sh`: install stack production server.
- `create-laravel-site.sh`: buat Nginx virtual host Laravel baru.
- `list-laravel-sites.sh`: lihat daftar website dan info production-nya.
- `backup-laravel-site.sh`: backup database, `.env`, upload, Nginx, dan PHP-FPM pool per site.
- `restore-laravel-site.sh`: restore database, `.env`, upload, Nginx, dan PHP-FPM pool dari backup.
- `check-laravel-site.sh`: health check Nginx, PHP-FPM, permission, `.env`, database, queue, SSL, dan HTTP.
- `grant-site-ssh-access.sh`: beri akses SSH key ke pengelola website tanpa sudo.
- `revoke-site-ssh-access.sh`: cabut akses SSH key pengelola website.
- `deploy-laravel.sh`: deploy project Laravel existing.
- `create-supervisor-laravel-queue.sh`: buat queue worker Laravel via Supervisor.
- `remove-laravel-site.sh`: hapus site dengan konfirmasi eksplisit untuk data.

Jadikan script executable:

```bash
chmod +x larastack *.sh
```

Semua script utama mendukung mode interaktif. Jalankan tanpa argumen untuk mode tanya-jawab, atau isi argumen jika ingin automation.

## Command Global

Pasang command global agar LaraStack bisa dijalankan dari folder mana pun:

```bash
sudo ./install-larastack-command.sh
```

Setelah itu jalankan:

```bash
larastack
```

atau:

```bash
larastack-installer
```

Keduanya membuka menu:

```text
1. Install server stack
2. Create website / handoff slot
3. List websites
4. Check website health
5. Deploy website
6. Backup website
7. Restore website
8. Create/update queue worker
9. Grant SSH access to manager
10. Revoke SSH access from manager
11. Remove website
12. Install/update global command
0. Exit
```

Command langsung juga tersedia:

```bash
larastack create-site --domain=example.com --handoff
larastack list-sites --summary
larastack check-site --domain=example.com
larastack backup --domain=example.com
```

Jika menjalankan `sudo ./install-laravel-server.sh`, command global ini juga dipasang otomatis di akhir instalasi.

## Instalasi Awal Server

Mode interaktif di Ubuntu 24.04 baru:

```bash
sudo ./install-laravel-server.sh
```

Script akan menanyakan timezone, opsi PHP 8.4, opsi Fail2ban, dan konfirmasi sebelum install berjalan.

Mode otomatis dengan default:

```bash
sudo ./install-laravel-server.sh --yes
```

Dengan Fail2ban:

```bash
sudo ./install-laravel-server.sh --yes --with-fail2ban
```

Dengan percobaan PHP 8.4 dari apt repository yang sudah tersedia:

```bash
sudo ./install-laravel-server.sh --yes --with-php84
```

Jika project butuh PHP 8.4 dan paket `php8.4-fpm` belum tersedia dari repository Ubuntu yang aktif, izinkan script menambahkan PPA `ppa:ondrej/php`:

```bash
sudo ./install-laravel-server.sh --yes --with-php84 --with-php84-ppa
```

Script akan menulis log ke:

```bash
/var/log/laravel-deploy/install.log
```

## Membuat Website Laravel Baru

Mode interaktif:

```bash
sudo ./create-laravel-site.sh
```

Script akan menanyakan:

- domain utama
- Linux site user
- private/public repository
- SSH deploy key untuk private repository
- alias domain
- path project
- versi PHP-FPM
- URL repository Git
- database MariaDB
- SSL Let's Encrypt
- Supervisor queue worker
- migrate dan database seeder

Mode argumen tetap tersedia untuk automation atau deploy berulang.

Tanpa repository:

```bash
sudo ./create-laravel-site.sh \
  --domain=example.com \
  --site-user=example
```

Membuat slot website kosong untuk pengelola:

```bash
sudo ./create-laravel-site.sh \
  --domain=example.com \
  --site-user=example \
  --handoff \
  --db-name=example_db \
  --db-user=example_user \
  --db-pass=random
```

Sekaligus beri akses SSH pengelola:

```bash
sudo ./create-laravel-site.sh \
  --domain=example.com \
  --site-user=example \
  --handoff \
  --manager-key-file=/tmp/pengelola.pub \
  --login-host=server.example.com
```

Dengan alias:

```bash
sudo ./create-laravel-site.sh \
  --domain=example.com \
  --site-user=example \
  --aliases=www.example.com
```

Dengan public repository:

```bash
sudo ./create-laravel-site.sh \
  --domain=example.com \
  --site-user=example \
  --repo=https://github.com/user/repo.git
```

Dengan migrate dan seeder:

```bash
sudo ./create-laravel-site.sh \
  --domain=example.com \
  --site-user=example \
  --repo=https://github.com/user/repo.git \
  --migrate \
  --seed
```

Dengan private repository:

```bash
sudo ./create-laravel-site.sh \
  --domain=example.com \
  --site-user=example \
  --private-repo \
  --repo=git@github.com:user/repo.git
```

Path default:

```bash
/home/example/public_html
```

Root Nginx akan diarahkan ke:

```bash
/home/example/public_html/public
```

Setiap site dibuat dengan:

- Linux user sendiri, contoh `example`
- home directory sendiri, contoh `/home/example`
- project path `/home/example/public_html`
- PHP-FPM pool sendiri, contoh `/etc/php/8.3/fpm/pool.d/example.conf`
- socket sendiri, contoh `/run/php/php8.3-fpm-example.sock`
- owner project `example:example`
- `.env` otomatis diisi `APP_URL`, `DB_CONNECTION`, `DB_HOST`, `DB_DATABASE`, `DB_USERNAME`, dan `DB_PASSWORD` jika file `.env` ada atau dibuat dari `.env.example`

### Mode Handoff Website Kosong

Mode `--handoff` atau `--empty-site` dipakai saat admin hanya menyiapkan slot hosting, lalu pengelola website yang mengisi aplikasi.

Saat menjalankan mode interaktif:

```bash
sudo ./create-laravel-site.sh
```

script akan menanyakan:

```text
Buat slot website kosong untuk pengelola?
```

Jika dijawab `y`, script akan:

- membuat Linux site user
- membuat `/home/{site_user}/public_html`
- membuat placeholder `/home/{site_user}/public_html/public/index.html`
- membuat Nginx server block ke `/home/{site_user}/public_html/public`
- membuat PHP-FPM pool per site user
- membuat database dan user database jika diminta
- membuat file handoff `/home/{site_user}/site-info.env`
- melewati clone repo, Composer, NPM, Artisan, migrate, seeder, dan queue

File handoff hanya bisa dibaca site user:

```bash
/home/example/site-info.env
```

Pengelola login lalu mengisi aplikasi:

```bash
ssh example@server.example.com
cd ~/public_html
```

Untuk Laravel, pengelola perlu memastikan entry point berada di:

```bash
/home/example/public_html/public/index.php
```

### Public Repo

1. Jalankan:
   ```bash
   sudo bash create-laravel-site.sh --interactive
   ```
2. Pilih repository public.
3. Masukkan URL HTTPS atau SSH.
4. Script clone repo dan menjalankan Composer/NPM/Artisan sebagai site user.

### Private Repo

1. Jalankan:
   ```bash
   sudo bash create-laravel-site.sh --interactive
   ```
2. Pilih private repo.
3. Script membuat Linux user dan SSH key.
4. Copy public key yang ditampilkan.
5. Masuk GitHub repo: Settings -> Deploy keys -> Add deploy key.
6. Paste public key.
7. Jangan centang write access kecuali butuh push.
8. Kembali ke terminal.
9. Konfirmasi.
10. Masukkan repo SSH:
    ```bash
    git@github.com:username/repo.git
    ```
11. Script clone repo sebagai site user dan lanjut setup.

## Membuat Database

Contoh membuat site sekaligus database:

```bash
sudo ./create-laravel-site.sh \
  --domain=example.com \
  --site-user=example \
  --repo=https://github.com/user/repo.git \
  --db-name=example_db \
  --db-user=example_user \
  --db-pass=random
```

Jika memakai `--db-pass=random`, password disimpan di:

```bash
/root/laravel-deploy/credentials/example.com.db.env
```

File tersebut hanya dapat dibaca root.

## Mengaktifkan SSL

Pastikan DNS domain sudah mengarah ke IP server, lalu:

```bash
sudo ./create-laravel-site.sh \
  --domain=example.com \
  --site-user=example \
  --aliases=www.example.com \
  --with-ssl \
  --email=admin@example.com
```

Jika `--email` tidak diisi, script tetap menjalankan Certbot dengan mode tanpa email.

Untuk site yang sudah ada, bisa jalankan Certbot manual:

```bash
sudo certbot --nginx -d example.com -d www.example.com
```

## Setup Queue

Saat membuat site:

```bash
sudo ./create-laravel-site.sh \
  --domain=example.com \
  --site-user=example \
  --repo=https://github.com/user/repo.git \
  --with-queue
```

Atau buat queue terpisah:

```bash
sudo ./create-supervisor-laravel-queue.sh
```

Mode interaktif dan `--domain` akan mencoba mendeteksi path, site user, dan versi PHP dari Nginx/PHP-FPM pool. Default user worker diambil dari owner project, bukan `www-data`.

Mode argumen:

```bash
sudo ./create-supervisor-laravel-queue.sh \
  --domain=example.com \
  --workers=1
```

Command queue yang dipakai:

```bash
php artisan queue:work redis --sleep=3 --tries=3 --timeout=120
```

## Workflow Deploy Laravel Dari GitHub

Contoh setup manual pertama kali setelah project di-clone:

```bash
cd /home/example/public_html
sudo -H -u example php8.3 /usr/local/bin/composer install --no-dev --optimize-autoloader
sudo -H -u example cp .env.example .env
sudo -H -u example php8.3 artisan key:generate
nano .env
sudo -H -u example php8.3 artisan migrate --force
sudo -H -u example npm ci
sudo -H -u example npm run build
sudo -H -u example php8.3 artisan storage:link
sudo -H -u example php8.3 artisan config:cache
sudo -H -u example php8.3 artisan route:cache
sudo -H -u example php8.3 artisan view:cache
sudo chown -R example:example /home/example/public_html
sudo chmod -R 775 storage bootstrap/cache
```

Deploy berikutnya:

```bash
sudo ./deploy-laravel.sh
```

Deploy interaktif akan mencoba mendeteksi domain, site user, versi PHP, dan path dari Nginx/PHP-FPM pool. Semua command deploy dijalankan sebagai site user.

Mode argumen:

```bash
sudo ./deploy-laravel.sh \
  --path=/home/example/public_html \
  --branch=main
```

Deploy memakai PHP tertentu:

```bash
sudo ./deploy-laravel.sh \
  --path=/home/example/public_html \
  --branch=main \
  --php=8.4
```

Deploy berdasarkan domain:

```bash
sudo ./deploy-laravel.sh \
  --domain=example.com \
  --branch=main
```

Deploy dengan seeder:

```bash
sudo ./deploy-laravel.sh \
  --domain=example.com \
  --branch=main \
  --seed
```

Deploy dengan maintenance mode:

```bash
sudo ./deploy-laravel.sh \
  --domain=example.com \
  --branch=main \
  --maintenance
```

Skip npm build:

```bash
sudo ./deploy-laravel.sh --path=/home/example/public_html --no-npm
```

Skip migration:

```bash
sudo ./deploy-laravel.sh --path=/home/example/public_html --no-migrate
```

Skip cache optimization:

```bash
sudo ./deploy-laravel.sh --path=/home/example/public_html --no-optimize
```

Log deploy disimpan di:

```bash
/var/log/laravel-deploy/deploy-example.com.log
```

## Melihat Website

Lihat semua website beserta detailnya:

```bash
sudo ./list-laravel-sites.sh
```

Tampilan ringkas:

```bash
sudo ./list-laravel-sites.sh --summary
```

Filter satu domain:

```bash
sudo ./list-laravel-sites.sh --domain=example.com
```

Output JSON untuk dashboard/monitoring:

```bash
sudo ./list-laravel-sites.sh --json
sudo ./list-laravel-sites.sh --domain=example.com --json
```

Info yang ditampilkan mencakup domain, alias, status enabled Nginx, `APP_URL`, SSL, site user, project path, owner, disk usage, PHP-FPM pool/socket, repository, branch, Laravel version, database name/user, credential file, dan status queue.

## Cek Health Website

Cek satu website:

```bash
sudo ./check-laravel-site.sh --domain=example.com
```

Cek semua website:

```bash
sudo ./check-laravel-site.sh --all
```

Lewati HTTP check jika domain belum pointing atau DNS belum aktif:

```bash
sudo ./check-laravel-site.sh --domain=example.com --no-http
```

Yang dicek:

- Nginx config dan status enabled site
- PHP-FPM pool, service, dan socket
- permission project, `storage`, `bootstrap/cache`, dan `.env`
- nilai penting `.env`
- koneksi database via Artisan
- status Supervisor queue
- masa berlaku SSL
- response HTTP/HTTPS domain

## Akses SSH Pengelola Website

Pengelola website sebaiknya login sebagai site user milik websitenya, tanpa akses `sudo`.

Minta pengelola mengirim public key dari laptopnya:

```bash
cat ~/.ssh/id_ed25519.pub
```

Beri akses:

```bash
sudo ./grant-site-ssh-access.sh \
  --domain=example.com \
  --key-file=/tmp/pengelola.pub \
  --host=server.example.com
```

Atau mode interaktif:

```bash
sudo ./grant-site-ssh-access.sh
```

Script akan:

- auto-detect site user dari domain/Nginx config
- menambahkan key ke `/home/{site_user}/.ssh/authorized_keys`
- set permission `.ssh` dan `authorized_keys`
- memastikan user tidak berada di grup `sudo`, `admin`, atau `wheel`
- menampilkan command login

Pengelola login dengan:

```bash
ssh example@server.example.com
```

Lihat key yang terpasang:

```bash
sudo ./revoke-site-ssh-access.sh --domain=example.com --list
```

Cabut akses:

```bash
sudo ./revoke-site-ssh-access.sh \
  --domain=example.com \
  --key-file=/tmp/pengelola.pub
```

## Cek Log

Nginx:

```bash
sudo tail -f /var/log/nginx/example.com.error.log
sudo tail -f /var/log/nginx/example.com.access.log
```

PHP-FPM:

```bash
sudo journalctl -u php8.3-fpm -f
```

Laravel:

```bash
sudo tail -f /home/example/public_html/storage/logs/laravel.log
```

Supervisor:

```bash
sudo supervisorctl status
sudo tail -f /var/log/supervisor/example.com/queue.log
```

Certbot:

```bash
sudo tail -f /var/log/letsencrypt/letsencrypt.log
```

## Restart Service

```bash
sudo systemctl restart nginx
sudo systemctl restart php8.3-fpm
sudo systemctl restart mariadb
sudo systemctl restart redis-server
sudo systemctl restart supervisor
```

Reload Nginx setelah perubahan config:

```bash
sudo nginx -t
sudo systemctl reload nginx
```

Restart queue:

```bash
sudo supervisorctl restart example.com-queue:*
```

## Backup Website

Backup satu website:

```bash
sudo ./backup-laravel-site.sh --domain=example.com
```

Backup semua website:

```bash
sudo ./backup-laravel-site.sh --all
```

Mode interaktif:

```bash
sudo ./backup-laravel-site.sh
```

Backup disimpan dengan timestamp:

```bash
/root/backups/laravel/example.com/YYYYMMDDHHMMSS
```

Isi backup:

- `database/database.sql.gz`
- `env/.env`
- `storage-app-public.tar.gz`
- `nginx/site.conf`
- `php-fpm/pool.conf`
- `manifest.env`

Symlink `latest` menunjuk ke backup terbaru:

```bash
/root/backups/laravel/example.com/latest
```

## Restore Website

Restore backup terbaru untuk satu domain:

```bash
sudo ./restore-laravel-site.sh --domain=example.com
```

Restore dari path backup tertentu:

```bash
sudo ./restore-laravel-site.sh \
  --backup=/root/backups/laravel/example.com/20260606153000
```

Script akan menampilkan ringkasan dan meminta konfirmasi ketik:

```text
RESTORE example.com
```

Untuk automation:

```bash
sudo ./restore-laravel-site.sh --domain=example.com --yes
```

Restore sebagian:

```bash
sudo ./restore-laravel-site.sh --domain=example.com --skip-db
sudo ./restore-laravel-site.sh --domain=example.com --skip-storage
sudo ./restore-laravel-site.sh --domain=example.com --skip-config
```

Saat restore, script akan:

- membuat site user jika belum ada
- restore Nginx config dan PHP-FPM pool
- restore `.env` dengan permission `0600`
- restore `storage/app/public`
- membuat database jika belum ada
- membuat atau update user database dari `.env`
- import `database.sql.gz`
- restart PHP-FPM dan reload Nginx

## Backup Database Sederhana

Buat folder backup:

```bash
sudo mkdir -p /root/backups/mysql
sudo chmod 700 /root/backups/mysql
```

Backup:

```bash
sudo mysqldump example_db | gzip > /root/backups/mysql/example_db-$(date +%F-%H%M%S).sql.gz
```

Restore:

```bash
gunzip -c /root/backups/mysql/example_db-YYYY-MM-DD-HHMMSS.sql.gz | sudo mysql example_db
```

## Menghapus Site

Mode interaktif:

```bash
sudo ./remove-laravel-site.sh
```

Hapus config Nginx, PHP-FPM pool, dan Supervisor saja:

```bash
sudo ./remove-laravel-site.sh --domain=example.com
```

Hapus file project juga. Script akan meminta konfirmasi eksplisit:

```bash
sudo ./remove-laravel-site.sh --domain=example.com --delete-files
```

Hapus database dan user. Script akan meminta konfirmasi eksplisit:

```bash
sudo ./remove-laravel-site.sh \
  --domain=example.com \
  --delete-db \
  --db-name=example_db \
  --db-user=example_user
```

Hapus Linux user atau SSL certificate juga bisa, dan tetap harus mengetik konfirmasi eksplisit:

```bash
sudo ./remove-laravel-site.sh --domain=example.com --delete-user --delete-ssl
```

## Troubleshooting

Git menolak repo dengan pesan `detected dubious ownership`:

```bash
sudo git config --global --add safe.directory /home/example/public_html
git config --global --add safe.directory /home/example/public_html
```

Pada workflow baru, `create-laravel-site.sh` menjalankan `git clone` sebagai site user sehingga normalnya tidak perlu `safe.directory`.

Composer gagal karena package butuh PHP 8.4:

```bash
sudo ./install-laravel-server.sh --yes --with-php84 --with-php84-ppa
sudo ./deploy-laravel.sh --path=/home/example/public_html --branch=main --php=8.4
```

Pastikan Nginx site juga memakai PHP-FPM yang sama:

```bash
sudo ./create-laravel-site.sh --domain=example.com --site-user=example --path=/home/example/public_html --php=8.4
```

## Catatan Production

- Jalankan script sebagai root atau dengan `sudo`.
- Jangan jalankan Certbot sebelum DNS domain mengarah ke server.
- `deploy-laravel.sh` memakai `git pull --ff-only`, jadi branch production harus bersih dari commit lokal yang belum dipush.
- OPcache production memakai `opcache.validate_timestamps=0`; deploy script akan restart PHP-FPM agar perubahan kode terbaca.
- Jika Laravel memakai route closure, `php artisan route:cache` akan gagal. Gunakan `--no-optimize` atau ubah route closure menjadi controller.
- Untuk VPS kecil, default worker queue adalah `1` agar tidak agresif memakai RAM.

## Referensi Metode Instalasi

- Composer installer dan checksum: https://getcomposer.org/download/
- NodeSource DEB distributions: https://nodesource.com/products/distributions
- NodeSource repository documentation: https://github.com/nodesource/distributions
- Ubuntu package PHP 8.3 FPM untuk Noble: https://packages.ubuntu.com/noble/php8.3-fpm
