#!/usr/bin/env bash
# Add a new project behind nginx with HTTPS in one command.
# Usage:   sudo add-site <domain> <local-port> <your-email>
# Example: sudo add-site invoicer.yourdomain.com 3001 you@email.com
#
# Point the domain's DNS A record at the server's static IP first.
set -euo pipefail

if [ $# -ne 3 ]; then
  echo "Usage: sudo add-site <domain> <local-port> <email>"
  exit 1
fi

DOMAIN="$1"
PORT="$2"
EMAIL="$3"
CONF="/etc/nginx/sites-available/$DOMAIN"

cat > "$CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    client_max_body_size 20m;

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_read_timeout 60s;
    }
}
EOF

ln -sf "$CONF" "/etc/nginx/sites-enabled/$DOMAIN"
nginx -t
systemctl reload nginx

# Gets the certificate, adds the 443 block and an HTTP->HTTPS redirect.
# Renewal is automatic (certbot installs a systemd timer).
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --redirect -m "$EMAIL"

echo "Live: https://$DOMAIN  ->  127.0.0.1:$PORT"
