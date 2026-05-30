# auto-install-cloudflare-tunnel

Interactive Bash tooling for installing and operating Docker-based Cloudflare
Tunnels from a single server. The script is designed for multiple tunnels and
multiple domains, with generated `config.yaml`, `docker-compose.yml`, backups,
basic validation, and Nginx reverse proxy templates.

## Quick start

```bash
chmod +x cloudflared-manager.sh

# Optional: choose where tunnel credentials and generated files are stored.
export CFM_HOME=/home/admin/server/cloudflared

./cloudflared-manager.sh
```

The default workspace is:

```text
~/cloudflared-manager
```

Inside the workspace the script creates:

```text
tunnels/<workspace>/config.yaml
tunnels/<workspace>/<tunnel-id>.json
docker-compose.yml
backups/
nginx-templates/
logs/
```

## Main menu features

- Install Docker (optional)
- Cloudflare Login
- Create Tunnel
- List Tunnels
- Delete Tunnel
- Create DNS Routes
- Generate `config.yaml`
- Generate `docker-compose.yml`
- Start Tunnel
- Stop Tunnel
- Restart Tunnel
- View Logs
- Health Dashboard
- Backup/Restore
- Nginx Template Generator
- Error Handling
- Validation

## Typical workflow

1. Run `Install Docker` if Docker is not installed.
2. Run `Cloudflare Login` for a tunnel workspace, for example `devth`.
3. Run `Create Tunnel`, for example `devth-tunnel`.
4. Run `Generate config.yaml` and add all hostnames for that tunnel.
5. Run `Create DNS Routes` for the same hostnames.
6. Run `Generate docker-compose.yml`.
7. Run `Start Tunnel`.
8. Use `Health Dashboard`, `View Logs`, and `Validate` to check the setup.

Repeat steps 2-5 for each separate tunnel/account/domain group. Regenerate
`docker-compose.yml` after adding or removing tunnel configs.

## Non-interactive commands

```bash
./cloudflared-manager.sh help
./cloudflared-manager.sh install-docker
./cloudflared-manager.sh login
./cloudflared-manager.sh create-tunnel
./cloudflared-manager.sh list
./cloudflared-manager.sh dns
./cloudflared-manager.sh config
./cloudflared-manager.sh compose
./cloudflared-manager.sh start
./cloudflared-manager.sh stop
./cloudflared-manager.sh restart
./cloudflared-manager.sh logs
./cloudflared-manager.sh dashboard
./cloudflared-manager.sh backup
./cloudflared-manager.sh restore
./cloudflared-manager.sh nginx
./cloudflared-manager.sh validate
```

## Example generated Cloudflare config

```yaml
tunnel: 820d3354-f7b7-4bcb-8907-2817a3b19e18
credentials-file: /home/nonroot/.cloudflared/820d3354-f7b7-4bcb-8907-2817a3b19e18.json

ingress:
  - hostname: drive.example.com
    service: http://host.docker.internal:80
  - hostname: photos.example.com
    service: http://host.docker.internal:80
  - service: http_status:404
```

## Example generated Docker Compose service

```yaml
services:
  cf_devth:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared_devth
    restart: unless-stopped
    user: "1000:1000"
    volumes:
      - ./tunnels/devth:/home/nonroot/.cloudflared:ro
    extra_hosts:
      - "host.docker.internal:host-gateway"
    command: tunnel --config /home/nonroot/.cloudflared/config.yaml run
```

## Security notes

- Do not commit `cert.pem`, tunnel credential JSON files, backup archives, or
  generated runtime logs.
- Use one workspace per tunnel group, for example `devth`, `wanyud`, or
  `beinyas`.
- Back up the workspace after creating or changing tunnels.
- Keep Docker and the `cloudflare/cloudflared` image updated.
