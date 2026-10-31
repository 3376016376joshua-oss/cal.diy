#!/usr/bin/env bash
# Pulls the image on the server, restarts the stack and waits until the site answers.
# It refuses to start the app until migrate-data.sh has finished (the seed accounts have publicly known passwords) and while the database has no accounts (the first-run setup page would let anyone create an admin).
# Usage: deploy/server/deploy.sh <ssh-target> [image-tag]
#   The tag defaults to latest; pass an older sha-xxxxxxx tag to roll back.
set -euo pipefail

target="${1:?usage: deploy.sh <ssh-target> [image-tag]}"
tag="${2:-latest}"
here="$(cd "$(dirname "$0")" && pwd)"
env_file="${CAL_ENV_FILE:-$here/.env.server}"

if [[ ! "$tag" =~ ^[A-Za-z0-9_.-]+$ ]]; then
  echo "Invalid image tag: $tag" >&2
  exit 1
fi
if [[ ! -f "$env_file" ]]; then
  echo "Missing $env_file. Run deploy/server/make-env.sh first." >&2
  exit 1
fi
domain="$(sed -nE "s/^CAL_DOMAIN=['\"]?([^'\"[:space:]]*).*/\1/p" "$env_file" | head -n1)"
if [[ -z "$domain" ]]; then
  echo "CAL_DOMAIN is not set in $env_file" >&2
  exit 1
fi

echo "Deploying image tag '$tag' to $target..."
# The tag is validated above, so it is safe to pass to the remote shell.
ssh "$target" "CAL_IMAGE_TAG='$tag' bash -s" <<'REMOTE'
set -euo pipefail
cd /opt/cal

# The account count below cannot tell the seed accounts from the real ones, so an import that stopped before deleting them would pass it.
if [ ! -e .deployed ] && [ ! -e .imported ]; then
  echo "The data import has not finished: migrate-data.sh writes /opt/cal/.imported only after it has removed the seed accounts, which have publicly known passwords. Run deploy/server/migrate-data.sh <ssh-target> 42,43 and check its account list first." >&2
  echo "If you restored a backup onto a new server instead, mark it with: ssh <ssh-target> touch /opt/cal/.imported" >&2
  exit 1
fi

docker compose up -d --wait database
# Without </dev/null, docker compose exec reads this script from stdin and silently skips the rest of it.
users="$(docker compose exec -T database sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select count(*) from users"' </dev/null)" || users=""
case "$users" in
  "" | *[!0-9]* | 0)
    echo "The server database has no accounts (or they could not be counted), so the app was not started: while the users table is empty, anyone can create the first admin." >&2
    echo "Run deploy/server/migrate-data.sh <ssh-target> 42,43 first, or restore a backup (README, Backups)." >&2
    exit 1
    ;;
esac

docker compose pull
docker compose up -d --remove-orphans
# From here on the database may hold bookings that exist nowhere else; migrate-data.sh refuses once this exists.
[ -e .deployed ] || date -u '+%Y-%m-%dT%H:%M:%SZ' > .deployed
REMOTE

url="https://$domain/auth/login"
code=""
for _ in $(seq 1 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" || true)"
  if [[ "$code" == "200" ]]; then
    echo "Healthy: $url"
    # Only dangling images go; sha- tags stay on the server for rollback.
    ssh "$target" 'docker image prune -f' >/dev/null || echo "Could not remove old images; this does not affect the site." >&2
    exit 0
  fi
  sleep 5
done

echo "Not healthy after 5 minutes (last HTTP status: ${code:-none}). Recent app and tunnel logs:" >&2
ssh "$target" 'cd /opt/cal && docker compose logs --tail 100 calcom cloudflared' >&2
exit 1
