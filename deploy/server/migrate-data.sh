#!/usr/bin/env bash
# One-time copy of the local Cal.diy database to the server. Run after bootstrap.sh and before deploy.sh.
# Usage: deploy/server/migrate-data.sh <ssh-target> <keep-user-ids>   e.g. root@203.0.113.10 42,43
set -euo pipefail

target="${1:?usage: migrate-data.sh <ssh-target> <keep-user-ids>}"
keep="${2:?usage: migrate-data.sh <ssh-target> <keep-user-ids>   e.g. 42,43}"
container="${LOCAL_DB_CONTAINER:-prisma-postgres-1}"
local_user="${LOCAL_DB_USER:-postgres}"
local_db="${LOCAL_DB_NAME:-calendso}"

if [[ ! "$keep" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
  echo "User ids must be a comma-separated list of numbers, got: $keep" >&2
  exit 1
fi

status=0
ssh "$target" 'test ! -e /opt/cal/.deployed' </dev/null || status=$?
if [[ "$status" -eq 1 ]]; then
  echo "deploy.sh has already started the app on $target (/opt/cal/.deployed), so its database may hold bookings that exist nowhere else. migrate-data.sh is only for the first import. To go back to an earlier state, restore a backup (deploy/server/README.md, Backups)." >&2
  exit 1
elif [[ "$status" -ne 0 ]]; then
  echo "Could not reach $target over SSH." >&2
  exit 1
fi

dump="$(mktemp)"
trap 'rm -f "$dump"' EXIT

echo "Dumping $local_db from local container $container..."
docker exec "$container" pg_dump -U "$local_user" -Fc "$local_db" > "$dump"
echo "Dump size: $(du -h "$dump" | cut -f1)"
scp "$dump" "$target:/opt/cal/backups/initial-import.dump"

# KEEP_USER_IDS is validated above, so it is safe to pass to the remote shell.
ssh "$target" "KEEP_USER_IDS='$keep' bash -s" <<'REMOTE'
set -euo pipefail
cd /opt/cal
trap 'rm -f backups/initial-import.dump' EXIT
# Without </dev/null, docker compose exec reads this script from stdin and silently skips the rest of it.
db() { docker compose exec -T database sh -c "$1" </dev/null; }

reset_hint="To start over, run on the server: cd /opt/cal && docker compose down -v (this deletes all server data), then re-run migrate-data.sh."

docker compose up -d database
# The Postgres entrypoint first runs a temporary server that listens on the unix socket only, so ask over TCP to wait for the real one.
ready=""
for _ in $(seq 1 30); do
  if db 'pg_isready -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
if [ -z "$ready" ]; then
  echo "The server database was not ready after 60 seconds. Check: cd /opt/cal && docker compose logs database" >&2
  exit 1
fi

tables="$(db 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select count(*) from pg_tables where schemaname = current_schema()"')"
if [ "$tables" != "0" ]; then
  # Decide on the data, not on the container: after a plain "docker compose down" the container is gone but the bookings are not.
  # Accounts outside the keep list mean the import stopped before the purge. If the count or Compose cannot answer, assume live: a wrong "safe to reset" hint costs far more than a missing one.
  others="$(db "psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -tAc 'select count(*) from users where id not in ($KEEP_USER_IDS)'")" || others=""
  app_containers="$(docker compose ps -a -q calcom </dev/null)" || app_containers="unknown"
  safe_to_reset=""
  case "$others" in
    "" | *[!0-9]* | 0) ;;
    *)
      if [ -z "$app_containers" ] && [ ! -e .deployed ]; then
        safe_to_reset=1
      fi
      ;;
  esac
  if [ -n "$safe_to_reset" ]; then
    echo "The server database already has $tables tables, including accounts you did not ask to keep, so the import stopped before the purge. Refusing to overwrite it. $reset_hint" >&2
  else
    echo "The server database already holds an imported or live dataset ($tables tables), and the site may hold newer bookings. It must NOT be reset. To go back to an earlier state, restore a backup instead (deploy/server/README.md, Backups)." >&2
  fi
  exit 1
fi

# A marker left by an earlier import must not vouch for this one.
rm -f .imported
docker compose exec -T database sh -c 'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-privileges --single-transaction --exit-on-error' < backups/initial-import.dump

expected="$(echo "$KEEP_USER_IDS" | tr ',' '\n' | wc -l | tr -d ' ')"
if ! found="$(db "psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -tAc 'select count(*) from users where id in ($KEEP_USER_IDS)'")"; then
  echo "Could not count the users to keep. Nothing was deleted. $reset_hint" >&2
  exit 1
fi
if [ "$found" != "$expected" ]; then
  echo "Only $found of the $expected users to keep exist. Nothing was deleted; check the ids. $reset_hint" >&2
  exit 1
fi

# The local database also holds seed accounts with publicly known passwords; they must not reach a public server.
if ! db "psql -v ON_ERROR_STOP=1 -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -1 -c 'delete from users where id not in ($KEEP_USER_IDS)'"; then
  echo "Deleting the other users failed, so the seed accounts are still in the server database. Do not deploy. $reset_hint" >&2
  exit 1
fi
# deploy.sh requires this before the first start: it proves the seed accounts are gone.
date -u '+%Y-%m-%dT%H:%M:%SZ' > .imported
echo "Users on the server now:"
db 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select id, username from users order by id"'
REMOTE

echo "Data copied. Next: deploy/server/deploy.sh $target"
