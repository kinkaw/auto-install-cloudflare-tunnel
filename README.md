# auto-install-cloudflare-tunnel

Interactive Bash manager for installing and operating multiple Cloudflare
Tunnels with Docker.

## Quick start

```bash
chmod +x cloudflare-tunnel-manager.sh
./cloudflare-tunnel-manager.sh
```

Optional custom data directory:

```bash
./cloudflare-tunnel-manager.sh --base-dir /home/admin/server/cloudflared
```

## Main features

- Optional Docker installation on apt-based Linux servers
- Cloudflare login using the official `cloudflare/cloudflared` Docker image
- Create, list, and delete tunnels
- Create DNS routes for one or many hostnames
- Generate `config.yaml` with multiple ingress hostnames per tunnel
- Generate a consolidated `docker-compose.yml`
- Start, stop, restart, and view tunnel logs
- Health dashboard for Docker, Compose, containers, disk usage, and status
- Backup and restore generated tunnel files
- Nginx reverse proxy template generator
- Validation for hostnames, services, cloudflared ingress config, and Compose

## Generated layout

By default the script writes local runtime files into `cloudflared-data/`:

```text
cloudflared-data/
  docker-compose.yml
  tunnels.tsv
  devth/
    cert.pem
    <tunnel-id>.json
    config.yaml
  wanyud/
    cert.pem
    <tunnel-id>.json
    config.yaml
  backups/
  nginx-templates/
```

`cloudflared-data/` is ignored by git because it can contain Cloudflare
credentials and server-specific generated files.

## Typical workflow

1. Run the script.
2. Choose **Install Docker** if Docker is not already installed.
3. Choose **Cloudflare Login** for the account or tunnel folder.
4. Choose **Create Tunnel**.
5. Generate `config.yaml` when prompted.
6. Create DNS routes when prompted.
7. Generate `docker-compose.yml`.
8. Start the tunnel service.
9. Use the health dashboard and logs to verify operation.

The script is Docker-first, so a host `cloudflared` package is not required.
