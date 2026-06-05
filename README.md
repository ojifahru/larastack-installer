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
- struktur multi-website di `/var/www`
- user web default `www-data`

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
  --domain=example.com
```

Dengan alias:

```bash
sudo ./create-laravel-site.sh \
  --domain=example.com \
  --aliases=www.example.com
```

Dengan clone dari GitHub:

```bash
sudo ./create-laravel-site.sh \
  --domain=example.com \
  --repo=https://github.com/user/repo.git
```

Path default:

```bash
/var/www/example.com
```

Root Nginx akan diarahkan ke:

```bash
/var/www/example.com/public
```

## Membuat Database

Contoh membuat site sekaligus database:

```bash
sudo ./create-laravel-site.sh \
  --domain=example.com \
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
  --path=/var/www/example.com \
  --php=8.3 \
  --workers=1
```

Command queue yang dipakai:

```bash
php artisan queue:work redis --sleep=3 --tries=3 --timeout=120
```

## Workflow Deploy Laravel Dari GitHub

Contoh setup manual pertama kali setelah project di-clone:

```bash
cd /var/www/example.com
composer install --no-dev --optimize-autoloader
cp .env.example .env
php artisan key:generate
nano .env
php artisan migrate --force
npm ci
npm run build
php artisan storage:link
php artisan config:cache
php artisan route:cache
php artisan view:cache
sudo chown -R www-data:www-data storage bootstrap/cache
sudo chmod -R 775 storage bootstrap/cache
```

Deploy berikutnya:

```bash
sudo ./deploy-laravel.sh
```

Mode argumen:

```bash
sudo ./deploy-laravel.sh \
  --path=/var/www/example.com \
  --branch=main
```

Skip npm build:

```bash
sudo ./deploy-laravel.sh --path=/var/www/example.com --no-npm
```

Skip migration:

```bash
sudo ./deploy-laravel.sh --path=/var/www/example.com --no-migrate
```

Skip cache optimization:

```bash
sudo ./deploy-laravel.sh --path=/var/www/example.com --no-optimize
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
sudo tail -f /var/www/example.com/storage/logs/laravel.log
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
