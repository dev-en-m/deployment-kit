#!/usr/bin/env bash
# One-time setup for a fresh Ubuntu 24.04 server (Lightsail or EC2).
# Run as the default "ubuntu" user:   sudo bash server-setup.sh
set -euo pipefail

echo "==> System updates"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get -y upgrade

echo "==> Docker Engine + Compose plugin"
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi

echo "==> Docker log rotation (stops logs from filling the disk)"
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
systemctl restart docker

echo "==> 'deploy' user (used by you and by GitHub Actions)"
if ! id deploy >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" deploy
fi
usermod -aG docker deploy
mkdir -p /home/deploy/.ssh
# Start with the same key you use for the ubuntu user.
# Later, append the GitHub Actions public key to this file too.
cp /home/ubuntu/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh
chmod 700 /home/deploy/.ssh
chmod 600 /home/deploy/.ssh/authorized_keys

echo "==> 2 GB swap file (safety net for a 2 GB RAM box)"
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo 'vm.swappiness=10' > /etc/sysctl.d/99-swap.conf
  sysctl --system >/dev/null
fi

echo "==> nginx, certbot, fail2ban"
apt-get install -y nginx certbot python3-certbot-nginx fail2ban
rm -f /etc/nginx/sites-enabled/default
# Needed so WebSockets work through the proxy
cat > /etc/nginx/conf.d/upgrade-map.conf <<'EOF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF
nginx -t && systemctl reload nginx
systemctl enable --now fail2ban

echo "==> SSH: key-only login"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl reload ssh

echo "==> App folders + shared Docker network"
mkdir -p /srv/apps /srv/shared
chown -R deploy:deploy /srv/apps /srv/shared
docker network inspect shared >/dev/null 2>&1 || docker network create shared

echo "==> Install the add-site helper (if it's next to this script)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/add-site.sh" ]; then
  install -m 755 "$SCRIPT_DIR/add-site.sh" /usr/local/bin/add-site
fi

echo
echo "Done. Next steps:"
echo "  1. Log in as deploy:   ssh deploy@<server-ip>"
echo "  2. Let the server pull private images from GHCR (once):"
echo "       echo <GITHUB_PAT_with_read:packages> | docker login ghcr.io -u <github-user> --password-stdin"
echo "  3. Start shared services from /srv/shared (Postgres, Redis)."
