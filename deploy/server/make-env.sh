#!/usr/bin/env bash
# Builds the server env file from the repo's .env.
# Usage: deploy/server/make-env.sh <hostname> [source-env] [output]
#   e.g. deploy/server/make-env.sh cal.reynenmeeting.org
set -euo pipefail

host="${1:?usage: make-env.sh <hostname> [source-env] [output]}"
here="$(cd "$(dirname "$0")" && pwd)"
src="${2:-$here/../../.env}"
out="${3:-$here/.env.server}"

if [[ ! "$host" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]]; then
  echo "Hostname must look like cal.example.com, got: $host" >&2
  exit 1
fi
if [[ ! -f "$src" ]]; then
  echo "Source env not found: $src" >&2
  exit 1
fi
if [[ -e "$out" ]]; then
  echo "$out already exists. Delete it first to regenerate it, but only before the first deploy: a new file has a new database password." >&2
  exit 1
fi

old_url="$(sed -nE "s/^NEXT_PUBLIC_WEBAPP_URL=['\"]?([^'\"[:space:]]*).*/\1/p" "$src" | head -n1)"
new_url="https://$host"
db_password="$(openssl rand -hex 24)"
overridden='^(CAL_DOMAIN|NEXT_PUBLIC_WEBAPP_URL|NEXT_PUBLIC_DISABLE_SIGNUP|NEXTAUTH_URL|POSTGRES_USER|POSTGRES_PASSWORD|POSTGRES_DB|DATABASE_URL|DATABASE_DIRECT_URL|TUNNEL_TOKEN)='

umask 077
{
  # The old address also appears in other keys (website URL, embed URL, Google OAuth JSON), so it is replaced everywhere.
  { grep -vE "$overridden" "$src" || true; } |
    OLD="$old_url" NEW="$new_url" perl -pe 'if (length $ENV{OLD}) { s/\Q$ENV{OLD}\E/$ENV{NEW}/g }'
  cat <<EOF

# --- Added by deploy/server/make-env.sh ---
CAL_DOMAIN=$host
NEXT_PUBLIC_WEBAPP_URL='$new_url'
NEXT_PUBLIC_DISABLE_SIGNUP=true
NEXTAUTH_URL='$new_url'
POSTGRES_USER=calcom
POSTGRES_PASSWORD=$db_password
POSTGRES_DB=calendso
DATABASE_URL='postgresql://calcom:$db_password@database:5432/calendso'
DATABASE_DIRECT_URL='postgresql://calcom:$db_password@database:5432/calendso'
# Paste the token of your Cloudflare tunnel (Zero Trust > Networks > Tunnels).
TUNNEL_TOKEN=
EOF
} > "$out"

echo "Wrote $out. Next: paste the Cloudflare tunnel token after TUNNEL_TOKEN=."
