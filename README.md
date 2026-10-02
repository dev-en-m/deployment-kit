# Deploy Kit: Many Docker Projects on One Small Server

This kit hosts many Docker projects on one small Ubuntu server, such as a Lightsail 2 GB plan or a small EC2 instance, with nginx in front and automatic HTTPS. Pushing to `main` deploys automatically. You manage everything else from your PC over SSH.

## How it works

```
GitHub push ──► GitHub Actions builds the image ──► GitHub Container Registry (GHCR)
                                  │
                                  └──► SSH into server ──► docker compose pull && up -d

Internet ──► nginx on the host (HTTPS via certbot)
               ├── app1.yourdomain.com ──► 127.0.0.1:3001 ──► container
               ├── app2.yourdomain.com ──► 127.0.0.1:3002 ──► container
               └── ...
                         all containers ──► shared Postgres + Redis (Docker network "shared")
```

nginx runs directly on the server, not in a container, so certbot can manage certificates on its own. Each app listens only on `127.0.0.1`, so the only way in from the internet is through nginx. All projects share one Postgres and one Redis to save RAM. The server never builds images, because builds can run a 2 GB machine out of memory.

## What's in the kit

```
deploy-kit/
├── README.md
├── server/
│   ├── server-setup.sh          One-time server bootstrap
│   └── add-site.sh              New subdomain + nginx + HTTPS in one command
├── shared-services/
│   └── docker-compose.yml       Shared Postgres + Redis  →  /srv/shared/
└── project-template/
    ├── docker-compose.server.yml   Per-project compose  →  /srv/apps/<repo-name>/
    └── .github/workflows/
        └── deploy.yml           Copy into each project repo
```

On the server, files end up laid out like this:

```
/srv/shared/            docker-compose.yml, .env (POSTGRES_PASSWORD)
/srv/apps/<repo-name>/  docker-compose.yml, .env (IMAGE_TAG + app secrets)
```

The folder name under `/srv/apps/` must exactly match the GitHub repository name, because the workflow uses the repo name to find it.

---

## 1. One-time server setup

### 1.1 Create the server

On Lightsail, create an Ubuntu 24.04 instance on the 2 GB plan, then attach a static IP (it's free while attached). In the instance's networking tab, make sure ports 22, 80, and 443 are open.

On EC2, launch Ubuntu 24.04, attach an Elastic IP, and open ports 22, 80, and 443 in the security group.

### 1.2 Run the setup script

From your PC:

```bash
scp -i ~/.ssh/your-key.pem -r server ubuntu@<server-ip>:~
ssh -i ~/.ssh/your-key.pem ubuntu@<server-ip>
sudo bash ~/server/server-setup.sh
```

The script:

- installs Docker and the Compose plugin
- creates a `deploy` user that can run Docker
- adds a 2 GB swap file
- sets up Docker log rotation
- installs nginx, certbot, and fail2ban
- turns off SSH password login
- creates `/srv/apps` and `/srv/shared`, plus the `shared` Docker network
- installs the `add-site` command

### 1.3 Set up your PC's SSH config

Edit `~/.ssh/config` on Mac or Linux, or `C:\Users\<you>\.ssh\config` on Windows:

```
Host demo
  HostName <server-ip>
  User deploy
  IdentityFile ~/.ssh/your-key.pem
```

Now `ssh demo` logs you straight in as the `deploy` user.

### 1.4 Create a key for GitHub Actions

Use a separate key for GitHub so you can revoke it without losing your own access:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/github-deploy -N "" -C "github-actions"
ssh-copy-id -i ~/.ssh/github-deploy.pub demo
```

If `ssh-copy-id` isn't available on Windows, paste the contents of `github-deploy.pub` as a new line in `/home/deploy/.ssh/authorized_keys` on the server.

You'll paste the private key (`~/.ssh/github-deploy`) into each repo's secrets in step 3.

### 1.5 Let the server pull your private images

Create a GitHub classic personal access token with only the `read:packages` permission. Then, on the server as `deploy`:

```bash
echo <TOKEN> | docker login ghcr.io -u <github-username> --password-stdin
```

### 1.6 Start the shared Postgres and Redis

```bash
scp shared-services/docker-compose.yml demo:/srv/shared/
ssh demo
cd /srv/shared
echo "POSTGRES_PASSWORD=$(openssl rand -hex 24)" > .env
docker compose up -d
```

---

## 2. Adding a new project

Repeat these steps for each project.

### 2.1 DNS

Create an A record for the subdomain, for example `invoicer.yourdomain.com`, pointing to the server's static IP. Wait for it to resolve (`ping invoicer.yourdomain.com`) before step 2.4, because certbot needs it.

### 2.2 Create the project's database (if it needs one)

```bash
ssh demo
docker exec -it postgres psql -U postgres -c "CREATE USER invoicer WITH PASSWORD 'change-me';"
docker exec -it postgres psql -U postgres -c "CREATE DATABASE invoicer OWNER invoicer;"
```

### 2.3 Create the project folder on the server

```bash
mkdir -p /srv/apps/invoicer          # must match the GitHub repo name
cd /srv/apps/invoicer
nano docker-compose.yml              # paste project-template/docker-compose.server.yml
nano .env
```

In `docker-compose.yml`, fill in three things:

- The image name: `ghcr.io/<github-user>/<repo-name>`, in lowercase.
- The port mapping `"127.0.0.1:<host-port>:<container-port>"`. The host port must be unique for each project; the container port is whatever your app listens on.
- `mem_limit`, sized to the app: around 128m for a small Go or Node API, 256–384m for Next.js or Django.

Example `.env`:

```
IMAGE_TAG=latest
DATABASE_URL=postgres://invoicer:change-me@postgres:5432/invoicer
REDIS_URL=redis://redis:6379/0
```

Inside the Docker network, the database host is `postgres`, not `localhost`.

### 2.4 Turn on nginx and HTTPS

```bash
sudo add-site invoicer.yourdomain.com 3001 you@email.com
```

The `deploy` user has no sudo access, so run this as `ubuntu` (`ssh ubuntu@<server-ip>`), or use the Lightsail browser terminal.

### 2.5 Connect the repo

1. Copy `project-template/.github/workflows/deploy.yml` into the repo at `.github/workflows/deploy.yml`.
2. Make sure the repo has a working `Dockerfile` at its root.
3. In the repo, go to **Settings → Secrets and variables → Actions** and add:
   - `SERVER_HOST`: the server's static IP
   - `SERVER_SSH_KEY`: the full contents of `~/.ssh/github-deploy`, the private key
4. Push to `main`. Watch the **Actions** tab. When it's green, open `https://invoicer.yourdomain.com`.

### Port register

Keep track of which port each project uses so you never reuse one:

| Port | Project | Domain |
|------|---------|--------|
| 3001 |         |        |
| 3002 |         |        |
| 3003 |         |        |

---

## 3. Day-to-day use

### Deploying

Push to `main`. That's it.

To redeploy without a code change, or to deploy another branch, use **Actions → Deploy → Run workflow**.

### Rolling back

You can roll back either way:

- **From GitHub:** use **Run workflow** on an older commit.
- **On the server:** this is faster, because the old image is still in the registry.
  ```bash
  ssh demo
  cd /srv/apps/invoicer
  nano .env                  # set IMAGE_TAG=<old commit SHA>
  docker compose pull && docker compose up -d
  ```

### Managing from your PC

The **VS Code Remote-SSH** extension lets you connect to `demo` and edit files on the server as if they were local.

A **Docker context** runs your local Docker commands against the server:

```bash
docker context create demo --docker "host=ssh://demo"
docker context use demo        # switch back later with: docker context use default
docker ps
docker logs -f <container>
docker stats                   # live RAM/CPU per container
```

**lazydocker** gives you a terminal dashboard for all containers once the `demo` context is active.

### Useful commands on the server

```bash
docker stats --no-stream                        # who's using the RAM
free -h                                         # RAM + swap
df -h                                           # disk
docker system df                                # Docker disk usage
docker image prune -a -f                        # free disk from old images
sudo nginx -t && sudo systemctl reload nginx    # after editing nginx configs
sudo certbot certificates                       # cert expiry dates
```

---

## 4. Backups

Dump all databases nightly instead of relying on many snapshots, which are billed per GB. As `deploy`, run `crontab -e` and add:

```
0 3 * * * docker exec postgres pg_dumpall -U postgres | gzip > /srv/shared/backup-$(date +\%a).sql.gz
```

This keeps a rolling seven days of backups, one file per weekday. Copy them off the server now and then (`scp demo:/srv/shared/backup-*.sql.gz .`). Taking an occasional manual Lightsail snapshot before big changes is also worth it.

## 5. Monitoring

Add each subdomain to a free external uptime checker such as UptimeRobot or Better Stack, so you get an email if a demo goes down. It uses no RAM on your server.

In the AWS console, set an AWS Budget alert at about $15/month.

---

## Troubleshooting

| Problem | Likely cause / fix |
|---|---|
| Actions fails at "Deploy on server" with `cd: no such file` | The `/srv/apps/<name>` folder name doesn't match the repo name exactly. |
| `denied` or `unauthorized` when pulling the image | The server isn't logged in to GHCR (step 1.5), or the token expired. |
| `invalid reference format` | The image name has uppercase letters. GHCR names must be lowercase. |
| 502 Bad Gateway | The container isn't running or uses a different port. Check `docker compose ps` and `docker compose logs`, and that the nginx port matches the compose host port. |
| certbot fails | DNS isn't pointing at the server yet, or port 80 is closed in the Lightsail/EC2 firewall. |
| Container keeps restarting with exit code 137 | It ran out of memory. Raise `mem_limit`, or check `docker stats` to see what else is using RAM. |
| Server is slow and swap is heavily used | Too many apps for 2 GB. Lower their memory limits, stop rarely used demos, or move static frontends to Cloudflare Pages or Netlify. |
| `exec format error` | Wrong CPU architecture. Use `linux/amd64` for Lightsail and `linux/arm64` for EC2 t4g in `deploy.yml`. |
| App can't reach the database | Use host `postgres`, not `localhost`, and make sure the compose file includes the `shared` network. |
