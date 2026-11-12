#!/usr/bin/env bash
# Prepares a fresh Ubuntu 24.04 server for Cal.diy. Safe to re-run; it also refreshes the compose file and env.
# Usage: deploy/server/bootstrap.sh <ssh-target>   e.g. root@203.0.113.10
set -euo pipefail

target="${1:?usage: bootstrap.sh <ssh-target>}"
here="$(cd "$(dirname "$0")" && pwd)"
env_file="${CAL_ENV_FILE:-$here/.env.server}"

if [[ ! -f "$env_file" ]]; then
  echo "Missing $env_file. Run deploy/server/make-env.sh first." >&2
  exit 1
fi
if ! grep -qE '^TUNNEL_TOKEN=.+' "$env_file"; then
  echo "TUNNEL_TOKEN is empty in $env_file. Paste the Cloudflare tunnel token first." >&2
  exit 1
fi

ssh "$target" 'bash -s' <<'REMOTE'
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then
  echo "Connect as root (root@<ip>): this setup installs packages and writes to /etc." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=600 update -q </dev/null
apt-get -o DPkg::Lock::Timeout=600 install -y -q docker.io docker-compose-v2 ufw </dev/null
systemctl enable --now docker

ufw allow OpenSSH
ufw --force enable

install -d -m 700 /opt/cal /opt/cal/backups

cat > /opt/cal/backup.sh <<'BACKUP'
#!/bin/sh
set -eu
cd /opt/cal
# The time is part of the name so a backup taken before an update never overwrites the nightly one from the same day.
file="backups/cal-$(date +%Y-%m-%d-%H%M%S).dump"
# Dump to a temporary name so a failed run never leaves a valid-looking backup.
docker compose exec -T database sh -c 'pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB"' > "$file.partial"
mv "$file.partial" "$file"
find backups -name 'cal-*.dump*' -mtime +6 -delete
echo "Saved /opt/cal/$file"
BACKUP
chmod 700 /opt/cal/backup.sh
echo '0 3 * * * root /opt/cal/backup.sh >> /var/log/cal-backup.log 2>&1' > /etc/cron.d/cal-backup
REMOTE

# A new .env would replace the database password and other secrets, so keep the previous one.
ssh "$target" 'if [ -f /opt/cal/.env ]; then (umask 077; cp /opt/cal/.env "/opt/cal/.env.bak-$(date +%Y%m%d-%H%M%S)"); fi'
scp "$here/docker-compose.yml" "$target:/opt/cal/docker-compose.yml"
scp "$env_file" "$target:/opt/cal/.env"
ssh "$target" 'chmod 600 /opt/cal/.env'

# Compose messages can quote fragments of secret values (for example the text after a dollar sign), so only their count is shown.
status=0
problems="$(ssh "$target" 'cd /opt/cal && docker compose config -q 2>&1' </dev/null)" || status=$?
if [[ "$status" -ne 0 || -n "$problems" ]]; then
  lines="$(printf '%s\n' "$problems" | grep -c . || true)"
  echo "Docker Compose reported a problem with /opt/cal/.env ($lines message lines, exit status $status)." >&2
  echo "If a value contains a dollar sign, put the value in single quotes or write each \$ as \$\$ in deploy/server/.env.server, then re-run bootstrap.sh." >&2
  echo "To read the messages yourself: ssh $target 'cd /opt/cal && docker compose config -q'" >&2
  exit 1
fi
echo "Server ready. Next: deploy/server/migrate-data.sh $target <keep-user-ids>"
