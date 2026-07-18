# VPS Deploy

## Stack
- Nginx on host: handles `sukavinagroup.net` and TLS
- Docker Compose: runs `postgres`, `api`, `web`

## Docker Compose
- `web` is published on `127.0.0.1:8080`
- `api` stays inside Docker network
- `postgres` stays inside Docker network

## Host Nginx
Copy `deploy/nginx/sukavina.conf` to:
`/etc/nginx/sites-available/sukavina.conf`

Then:
```bash
sudo ln -sf /etc/nginx/sites-available/sukavina.conf /etc/nginx/sites-enabled/sukavina.conf
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl reload nginx
```

## TLS
Install certbot:
```bash
sudo apt-get update
sudo apt-get install -y certbot python3-certbot-nginx
sudo certbot --nginx -d sukavinagroup.net -d www.sukavinagroup.net
```

## Start stack
```bash
cd /opt/projects/sukavina
docker compose up -d --build
docker compose ps
```
