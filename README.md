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
- `deploy-laravel.sh`: deploy project Laravel existing.
- `create-supervisor-laravel-queue.sh`: buat queue worker Laravel via Supervisor.
- `remove-laravel-site.sh`: hapus site dengan konfirmasi eksplisit untuk data.

Jadikan script executable:

```bash
chmod +x *.sh
```

Semua script utama mendukung mode interaktif. Jalankan tanpa argumen untuk mode tanya-jawab, atau isi argumen jika ingin automation.

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

Mode argumen tetap tersedia untuk automation atau deploy berulang.

Tanpa repository:

```bash
sudo ./create-laravel-site.sh \
  --domain=example.com \
  --site-user=example
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

Mode argumen:

```bash
sudo ./create-supervisor-laravel-queue.sh \
  --name=example.com \
  --path=/home/example/public_html \
  --php=8.3 \
  --user=example \
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
sudo tail -f /var/log/supervisor/example.com-queue.log
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

Hapus config Nginx dan Supervisor saja:

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
