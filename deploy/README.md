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

## GitHub to VPS sync

Android Studio and the local development workspace use the GitHub repository as
the source of truth. The workflow `.github/workflows/sync-vps.yml` pulls `main`
onto the VPS after every push and rebuilds the Docker stack when a Compose file
is present.

Configure these GitHub repository secrets before enabling the workflow:

- `VPS_HOST`: VPS IP or hostname
- `VPS_PORT`: SSH port, normally `22`
- `VPS_USER`: SSH user, for example `root`
- `VPS_SSH_PRIVATE_KEY`: private deploy key whose public key is in the VPS user's `authorized_keys`
- `VPS_PROJECT_DIR`: optional project path; defaults to `/opt/projects/sukavina`

The workflow uses `git pull --ff-only`, so it stops safely if the VPS contains
local commits or uncommitted changes instead of overwriting them.
