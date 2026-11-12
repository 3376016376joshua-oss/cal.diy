# Self-hosted Cal.diy Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run Cal.diy 24/7 at `https://cal.reynenmeeting.org` on one VPS, built by GitHub Actions and updated with one command.

**Architecture:** A GitHub Actions workflow builds the repo's existing `Dockerfile` into `ghcr.io/3376016376joshua-oss/cal.diy`. On the VPS, Docker Compose runs Postgres 18, that image, and `cloudflared` (a named Cloudflare Tunnel), with no inbound ports except SSH. Bash scripts run from the Mac generate the server env, set up the server, copy the local database once (keeping only real accounts), deploy, and pull backups.

**Tech Stack:** GitHub Actions (docker/build-push-action), GHCR, Docker Compose v2, Postgres 18, Cloudflare Tunnel (`cloudflare/cloudflared`), Bash, Ubuntu 24.04.

**Spec:** `docs/superpowers/specs/2026-10-31-self-host-deploy-design.md`

## Global Constraints

- Public hostname: `cal.reynenmeeting.org`.
- Image: `ghcr.io/3376016376joshua-oss/cal.diy`, tags `latest` (default branch only) and `sha-<7 chars>`; platform `linux/amd64`.
- Server: Ubuntu 24.04, x86_64, at least 4 GB RAM, SSH as `root`, app files in `/opt/cal`.
- Postgres `postgres:18` on the server and in CI (the local database is Postgres 18.6).
- Users kept on the server: ids `42,43`. Every other user is deleted after the data copy.
- No upstream file changes except one `.gitignore` line. All new files live in `deploy/server/` plus `.github/workflows/build-image.yml`.
- No secrets in the repo or the image. `deploy/server/.env.server` is gitignored and written with mode 600; `/opt/cal/.env` is mode 600.
- Keep `NEXTAUTH_SECRET` and `CALENDSO_ENCRYPTION_KEY` unchanged from the local `.env`.
- Only SSH is open inbound; no Compose service has a `ports:` entry.
- `NEXT_PUBLIC_*` values are build-time; set them in the workflow, never rely on the server env for them. The one exception is `NEXT_PUBLIC_WEBAPP_URL`, which `scripts/start.sh` rewrites into the built files at container start, so the server env must set it.
- Commit only the files each task names (`apps/web/next.config.ts` and `.claude/launch.json` have unrelated local changes; never stage them). Conventional commit messages ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Lint tools run in Docker, nothing installed: `koalaman/shellcheck:stable`, `rhysd/actionlint:latest`.
- Branch `feat/self-host-deploy`; draft PR into `3376016376joshua-oss/cal.diy` `main`, never upstream. Push only after the owner approves.

## File Structure

| File | Responsibility |
|---|---|
| `deploy/server/make-env.sh` | Generate `deploy/server/.env.server` from the repo `.env` for the server |
| `deploy/server/tests/server-scripts.test.sh` | Server-free checks: env generation, Compose parsing, script input guards, syntax |
| `deploy/server/docker-compose.yml` | Server stack: `database`, `calcom`, `cloudflared` |
| `deploy/server/.env.server.example` | Keys the deployment adds or overrides, no values |
| `.gitignore` | One line so the example env is tracked |
| `deploy/server/bootstrap.sh` | First-time, re-runnable server setup (Docker, firewall, files, backups) |
| `deploy/server/migrate-data.sh` | One-time local-to-server database copy and seed-account cleanup |
| `deploy/server/deploy.sh` | Pull, restart, health check, rollback by tag |
| `deploy/server/pull-backup.sh` | Copy the newest server backup to the Mac |
| `.github/workflows/build-image.yml` | Build, smoke-test and publish the image |
| `deploy/server/README.md` | Runbook for the owner |

---

### Task 1: Server env generator

**Files:**
- Create: `deploy/server/make-env.sh`
- Test: `deploy/server/tests/server-scripts.test.sh`

**Interfaces:**
- Consumes: the repo's `.env` (keys `NEXT_PUBLIC_WEBAPP_URL`, `NEXTAUTH_URL`, `DATABASE_URL`, `DATABASE_DIRECT_URL`, and everything else copied as is).
- Produces: `make-env.sh <hostname> [source-env] [output]`; default source `<repo>/.env`, default output `deploy/server/.env.server`. The output ends with these keys, which Tasks 2 to 4 rely on: `CAL_DOMAIN`, `NEXT_PUBLIC_WEBAPP_URL`, `NEXTAUTH_URL`, `POSTGRES_USER=calcom`, `POSTGRES_PASSWORD` (48 hex chars), `POSTGRES_DB=calendso`, `DATABASE_URL`, `DATABASE_DIRECT_URL` (both `postgresql://calcom:<pw>@database:5432/calendso`), `TUNNEL_TOKEN=` (empty). Test helpers `check <name> <cmd...>`, `refuses <cmd...>`, `quiet <cmd...>`, variables `$server_dir`, `$work`, `$out`, and a `# --- summary ---` marker line that later tasks insert blocks above.

- [ ] **Step 1: Write the failing test**

Create `deploy/server/tests/server-scripts.test.sh`:

```bash
#!/usr/bin/env bash
# Checks the deploy scripts without a server: env generation, Compose parsing and input guards.
# Usage: deploy/server/tests/server-scripts.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
server_dir="$(cd "$here/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

check() {
  local name="$1"
  shift
  if "$@"; then
    echo "ok   - $name"
  else
    echo "FAIL - $name"
    failures=$((failures + 1))
  fi
}

refuses() {
  if "$@" >/dev/null 2>&1; then return 1; fi
  return 0
}

quiet() {
  "$@" >/dev/null 2>&1
}

# --- make-env.sh ---
cat > "$work/source.env" <<'EOF'
NEXT_PUBLIC_WEBAPP_URL='https://old-words.trycloudflare.com'
NEXT_PUBLIC_WEBSITE_URL='https://old-words.trycloudflare.com'
NEXTAUTH_URL='https://old-words.trycloudflare.com'
DATABASE_URL="postgresql://postgres:@localhost:5450/calendso"
DATABASE_DIRECT_URL="postgresql://postgres:@localhost:5450/calendso"
INSIGHTS_DATABASE_URL=
NEXTAUTH_SECRET=keep-this-secret
CALENDSO_ENCRYPTION_KEY=keep-this-key
ENABLE_ASYNC_TASKER="false" # set to "true" to enable
GOOGLE_API_CREDENTIALS='{"web":{"redirect_uris":["https://old-words.trycloudflare.com/api/integrations/googlecalendar/callback"]}}'
EOF

out="$work/.env.server"
check "make-env succeeds" quiet "$server_dir/make-env.sh" cal.example.com "$work/source.env" "$out"
check "old tunnel address is gone" refuses grep -q trycloudflare "$out"
check "webapp URL points to the new host" grep -qx "NEXT_PUBLIC_WEBAPP_URL='https://cal.example.com'" "$out"
check "auth URL points to the new host" grep -qx "NEXTAUTH_URL='https://cal.example.com'" "$out"
check "exactly one NEXTAUTH_URL" test "$(grep -c '^NEXTAUTH_URL=' "$out")" = 1
check "website URL is rewritten" grep -qx "NEXT_PUBLIC_WEBSITE_URL='https://cal.example.com'" "$out"
check "Google redirect URI is rewritten" grep -q 'https://cal.example.com/api/integrations/googlecalendar/callback' "$out"
check "auth secret is unchanged" grep -qx "NEXTAUTH_SECRET=keep-this-secret" "$out"
check "encryption key is unchanged" grep -qx "CALENDSO_ENCRYPTION_KEY=keep-this-key" "$out"
check "other database URLs are kept" grep -qx "INSIGHTS_DATABASE_URL=" "$out"
check "exactly one DATABASE_URL" test "$(grep -c '^DATABASE_URL=' "$out")" = 1
check "database URL targets the compose service" grep -qE "^DATABASE_URL='postgresql://calcom:[0-9a-f]{48}@database:5432/calendso'$" "$out"
check "direct database URL matches" test "$(sed -n 's/^DATABASE_DIRECT_URL=//p' "$out")" = "$(sed -n 's/^DATABASE_URL=//p' "$out")"
check "CAL_DOMAIN is set" grep -qx "CAL_DOMAIN=cal.example.com" "$out"
check "tunnel token is left for the owner" grep -qx "TUNNEL_TOKEN=" "$out"
check "output is readable only by the owner" test "$(stat -f %Lp "$out" 2>/dev/null || stat -c %a "$out")" = 600
check "make-env refuses to overwrite" refuses "$server_dir/make-env.sh" cal.example.com "$work/source.env" "$out"
check "make-env rejects a bare word as hostname" refuses "$server_dir/make-env.sh" localhost "$work/source.env" "$work/other.env"

# --- summary ---
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All checks passed"
```

Then make it executable:

```bash
chmod +x deploy/server/tests/server-scripts.test.sh
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `deploy/server/tests/server-scripts.test.sh`
Expected: `FAIL - make-env succeeds` and most other checks fail, last line `N check(s) failed`, exit code 1 (the script does not exist yet).

- [ ] **Step 3: Write the implementation**

Create `deploy/server/make-env.sh`:

```bash
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
  echo "$out already exists. Delete it first to regenerate it." >&2
  exit 1
fi

old_url="$(sed -nE "s/^NEXT_PUBLIC_WEBAPP_URL=['\"]?([^'\"[:space:]]*).*/\1/p" "$src" | head -n1)"
new_url="https://$host"
db_password="$(openssl rand -hex 24)"
overridden='^(CAL_DOMAIN|NEXT_PUBLIC_WEBAPP_URL|NEXTAUTH_URL|POSTGRES_USER|POSTGRES_PASSWORD|POSTGRES_DB|DATABASE_URL|DATABASE_DIRECT_URL|TUNNEL_TOKEN)='

umask 077
{
  # The old address also appears in other keys (website URL, embed URL, Google OAuth JSON), so it is replaced everywhere.
  { grep -vE "$overridden" "$src" || true; } |
    OLD="$old_url" NEW="$new_url" perl -pe 'if (length $ENV{OLD}) { s/\Q$ENV{OLD}\E/$ENV{NEW}/g }'
  cat <<EOF

# --- Added by deploy/server/make-env.sh ---
CAL_DOMAIN=$host
NEXT_PUBLIC_WEBAPP_URL='$new_url'
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
```

Then:

```bash
chmod +x deploy/server/make-env.sh
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `deploy/server/tests/server-scripts.test.sh`
Expected: every line starts with `ok   -`, last line `All checks passed`, exit code 0.

- [ ] **Step 5: Lint**

Run: `docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable --severity=warning deploy/server/make-env.sh deploy/server/tests/server-scripts.test.sh`
Expected: no output, exit code 0.

- [ ] **Step 6: Commit**

```bash
git add deploy/server/make-env.sh deploy/server/tests/server-scripts.test.sh
git commit -m "feat(deploy): generate the server env from the local .env

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Server Compose stack and env example

**Files:**
- Create: `deploy/server/docker-compose.yml`
- Create: `deploy/server/.env.server.example`
- Modify: `.gitignore:42` (after the `!.env.example` line)
- Test: `deploy/server/tests/server-scripts.test.sh` (insert a block)

**Interfaces:**
- Consumes: the keys produced by Task 1 (`POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, `TUNNEL_TOKEN`, all app keys via `env_file`).
- Produces: Compose project `cal` with services `database`, `calcom`, `cloudflared`; volume `database-data`; image tag variable `CAL_IMAGE_TAG` (default `latest`). Server path `/opt/cal/docker-compose.yml` reads `/opt/cal/.env`. Tasks 3 and 4 call `docker compose exec -T database ...`, `docker compose pull`, `docker compose up -d`, `docker compose logs calcom`.

- [ ] **Step 1: Write the failing test**

In `deploy/server/tests/server-scripts.test.sh`, insert this block directly above the `# --- summary ---` line:

```bash
# --- docker-compose.yml and .env.server.example ---
cp "$server_dir/docker-compose.yml" "$work/docker-compose.yml" 2>/dev/null
cp "$out" "$work/.env"
if config="$(docker compose --project-directory "$work" -f "$work/docker-compose.yml" config 2>&1)"; then
  compose_ok=0
else
  compose_ok=1
  echo "$config"
fi
check "compose parses the generated env" test "$compose_ok" -eq 0
check "inline comment is dropped from ENABLE_ASYNC_TASKER" grep -qE '^ +ENABLE_ASYNC_TASKER: "?false"?$' <<< "$config"
check "app uses the GHCR image, latest by default" grep -q 'image: ghcr.io/3376016376joshua-oss/cal.diy:latest' <<< "$config"
check "app knows where the database is" grep -q 'DATABASE_HOST: database:5432' <<< "$config"
check "no service publishes a port" refuses grep -q 'published:' <<< "$config"

missing=""
for key in CAL_DOMAIN NEXT_PUBLIC_WEBAPP_URL NEXTAUTH_URL POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB DATABASE_URL DATABASE_DIRECT_URL TUNNEL_TOKEN; do
  grep -q "^$key=" "$server_dir/.env.server.example" 2>/dev/null || missing="$missing $key"
done
check "example env lists the generated keys${missing:+ (missing:$missing)}" test -z "$missing"
check "example env is tracked by git" refuses git -C "$server_dir" check-ignore -q .env.server.example
check "real env stays ignored by git" quiet git -C "$server_dir" check-ignore -q .env.server
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `deploy/server/tests/server-scripts.test.sh`
Expected: the Task 1 checks pass; `FAIL - compose parses the generated env`, `FAIL - example env lists the generated keys (missing: ...)`, `FAIL - example env is tracked by git`; exit code 1.

- [ ] **Step 3: Write the Compose file**

Create `deploy/server/docker-compose.yml`:

```yaml
# Production stack for one server. Lives at /opt/cal/docker-compose.yml next to /opt/cal/.env.
name: cal

services:
  database:
    image: postgres:18
    restart: always
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    volumes:
      - database-data:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 10

  # No ports are published: the only way in from the internet is the Cloudflare tunnel.
  calcom:
    image: ghcr.io/3376016376joshua-oss/cal.diy:${CAL_IMAGE_TAG:-latest}
    restart: always
    env_file: .env
    environment:
      DATABASE_HOST: database:5432
    depends_on:
      database:
        condition: service_healthy

  cloudflared:
    image: cloudflare/cloudflared:latest
    restart: always
    command: tunnel --no-autoupdate run
    environment:
      TUNNEL_TOKEN: ${TUNNEL_TOKEN}
    depends_on:
      - calcom

volumes:
  database-data:
```

- [ ] **Step 4: Write the env example**

Create `deploy/server/.env.server.example`:

```bash
# deploy/server/make-env.sh writes deploy/server/.env.server: your repo .env plus the keys below.
# bootstrap.sh copies it to /opt/cal/.env on the server. Never commit the real file.
CAL_DOMAIN=
NEXT_PUBLIC_WEBAPP_URL=
NEXTAUTH_URL=
POSTGRES_USER=
POSTGRES_PASSWORD=
POSTGRES_DB=
DATABASE_URL=
DATABASE_DIRECT_URL=
TUNNEL_TOKEN=
```

- [ ] **Step 5: Track the example in git**

In `.gitignore`, directly after the line `!.env.example` (line 42), add:

```
!deploy/server/.env.server.example
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `deploy/server/tests/server-scripts.test.sh`
Expected: all lines `ok   -`, last line `All checks passed`, exit code 0.

- [ ] **Step 7: Commit**

```bash
git add deploy/server/docker-compose.yml deploy/server/.env.server.example .gitignore deploy/server/tests/server-scripts.test.sh
git commit -m "feat(deploy): add the server compose stack with a Cloudflare tunnel

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Server scripts (bootstrap, data copy, deploy, backup pull)

**Files:**
- Create: `deploy/server/bootstrap.sh`
- Create: `deploy/server/migrate-data.sh`
- Create: `deploy/server/deploy.sh`
- Create: `deploy/server/pull-backup.sh`
- Test: `deploy/server/tests/server-scripts.test.sh` (insert a block)

**Interfaces:**
- Consumes: `deploy/server/.env.server` from Task 1 (override path with `CAL_ENV_FILE`), `deploy/server/docker-compose.yml` and service names from Task 2, local container `prisma-postgres-1` (override with `LOCAL_DB_CONTAINER`, `LOCAL_DB_USER`, `LOCAL_DB_NAME`).
- Produces (all take `<ssh-target>` like `root@203.0.113.10` first):
  - `bootstrap.sh <ssh-target>`: server has Docker, ufw (SSH only), `/opt/cal/{docker-compose.yml,.env,backup.sh,backups/}`, `/etc/cron.d/cal-backup`.
  - `migrate-data.sh <ssh-target> <keep-user-ids>` (e.g. `42,43`).
  - `deploy.sh <ssh-target> [image-tag]` (default `latest`).
  - `pull-backup.sh <ssh-target>` (destination `CAL_BACKUP_DIR`, default `~/cal-backups`).
  - On the server: `/opt/cal/backup.sh` writes `/opt/cal/backups/cal-YYYY-MM-DD.dump`.

- [ ] **Step 1: Write the failing test**

In `deploy/server/tests/server-scripts.test.sh`, insert this block directly above the `# --- summary ---` line. The address `192.0.2.1` is reserved for documentation and is never contacted, because every guard runs before SSH.

```bash
# --- input guards (no server needed) ---
check "bootstrap needs a target" refuses "$server_dir/bootstrap.sh"
check "bootstrap refuses an empty tunnel token" refuses env CAL_ENV_FILE="$out" "$server_dir/bootstrap.sh" root@192.0.2.1
check "migrate-data needs users to keep" refuses "$server_dir/migrate-data.sh" root@192.0.2.1
check "migrate-data rejects a malformed user list" refuses "$server_dir/migrate-data.sh" root@192.0.2.1 "42;43"
check "deploy needs a target" refuses "$server_dir/deploy.sh"
check "deploy rejects an unsafe image tag" refuses env CAL_ENV_FILE="$out" "$server_dir/deploy.sh" root@192.0.2.1 'latest;reboot'
check "pull-backup needs a target" refuses "$server_dir/pull-backup.sh"
for script in bootstrap.sh migrate-data.sh deploy.sh pull-backup.sh make-env.sh; do
  check "$script is executable" test -x "$server_dir/$script"
  check "$script has valid bash syntax" bash -n "$server_dir/$script"
done
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `deploy/server/tests/server-scripts.test.sh`
Expected: Tasks 1 and 2 checks pass. The `needs a target` and `refuses` guard checks pass trivially, because a missing file also fails. `FAIL - bootstrap.sh is executable`, `FAIL - bootstrap.sh has valid bash syntax` and the same two for `migrate-data.sh`, `deploy.sh`, `pull-backup.sh`; exit code 1.

- [ ] **Step 3: Write `bootstrap.sh`**

Create `deploy/server/bootstrap.sh`:

```bash
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
apt-get update -q
apt-get install -y -q docker.io docker-compose-v2 ufw
systemctl enable --now docker

ufw allow OpenSSH
ufw --force enable

install -d -m 700 /opt/cal /opt/cal/backups

cat > /opt/cal/backup.sh <<'BACKUP'
#!/bin/sh
set -eu
cd /opt/cal
file="backups/cal-$(date +%F).dump"
# Dump to a temporary name so a failed run never leaves a valid-looking backup.
docker compose exec -T database sh -c 'pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB"' > "$file.partial"
mv "$file.partial" "$file"
find backups -name 'cal-*.dump' -mtime +6 -delete
echo "Saved /opt/cal/$file"
BACKUP
chmod 700 /opt/cal/backup.sh
echo '0 3 * * * root /opt/cal/backup.sh >> /var/log/cal-backup.log 2>&1' > /etc/cron.d/cal-backup
REMOTE

scp "$here/docker-compose.yml" "$target:/opt/cal/docker-compose.yml"
scp "$env_file" "$target:/opt/cal/.env"
ssh "$target" 'chmod 600 /opt/cal/.env'
echo "Server ready. Next: deploy/server/migrate-data.sh $target <keep-user-ids>"
```

- [ ] **Step 4: Write `migrate-data.sh`**

Create `deploy/server/migrate-data.sh`:

```bash
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
db() { docker compose exec -T database sh -c "$1"; }

docker compose up -d database
for _ in $(seq 1 30); do
  if db 'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"' >/dev/null 2>&1; then break; fi
  sleep 2
done

tables="$(db 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select count(*) from pg_tables where schemaname = current_schema()"')"
if [ "$tables" != "0" ]; then
  echo "The server database already has $tables tables. Refusing to overwrite it." >&2
  exit 1
fi

db 'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-privileges --single-transaction --exit-on-error' < backups/initial-import.dump

expected="$(echo "$KEEP_USER_IDS" | tr ',' '\n' | wc -l | tr -d ' ')"
found="$(db "psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -tAc 'select count(*) from users where id in ($KEEP_USER_IDS)'")"
if [ "$found" != "$expected" ]; then
  echo "Only $found of the $expected users to keep exist. Nothing was deleted; check the ids." >&2
  exit 1
fi

# The local database also holds seed accounts with publicly known passwords; they must not reach a public server.
db "psql -v ON_ERROR_STOP=1 -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -1 -c 'delete from users where id not in ($KEEP_USER_IDS)'"
echo "Users on the server now:"
db 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select id, username from users order by id"'
rm backups/initial-import.dump
REMOTE

echo "Data copied. Next: deploy/server/deploy.sh $target"
```

- [ ] **Step 5: Write `deploy.sh`**

Create `deploy/server/deploy.sh`:

```bash
#!/usr/bin/env bash
# Pulls the image on the server, restarts the stack and waits until the site answers.
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
ssh "$target" "cd /opt/cal && export CAL_IMAGE_TAG='$tag' && docker compose pull && docker compose up -d --remove-orphans"

url="https://$domain/auth/login"
code=""
for _ in $(seq 1 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" || true)"
  if [[ "$code" == "200" ]]; then
    echo "Healthy: $url"
    exit 0
  fi
  sleep 5
done

echo "Not healthy after 5 minutes (last HTTP status: ${code:-none}). Recent app logs:" >&2
ssh "$target" 'cd /opt/cal && docker compose logs --tail 100 calcom' >&2
exit 1
```

- [ ] **Step 6: Write `pull-backup.sh`**

Create `deploy/server/pull-backup.sh`:

```bash
#!/usr/bin/env bash
# Copies the newest server backup to this computer.
# Usage: deploy/server/pull-backup.sh <ssh-target>   (saves to ~/cal-backups unless CAL_BACKUP_DIR is set)
set -euo pipefail

target="${1:?usage: pull-backup.sh <ssh-target>}"
dest="${CAL_BACKUP_DIR:-$HOME/cal-backups}"

latest="$(ssh "$target" 'ls -1t /opt/cal/backups/cal-*.dump 2>/dev/null | head -n1')"
if [[ -z "$latest" ]]; then
  echo "No backups on $target yet. Make one with: ssh $target /opt/cal/backup.sh" >&2
  exit 1
fi

mkdir -p "$dest"
scp "$target:$latest" "$dest/"
echo "Saved $dest/$(basename "$latest")"
```

- [ ] **Step 7: Make the scripts executable**

```bash
chmod +x deploy/server/bootstrap.sh deploy/server/migrate-data.sh deploy/server/deploy.sh deploy/server/pull-backup.sh
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `deploy/server/tests/server-scripts.test.sh`
Expected: all lines `ok   -`, last line `All checks passed`, exit code 0. It finishes within a few seconds; a hang means a guard is missing and a script is trying to reach `192.0.2.1`.

- [ ] **Step 9: Lint**

Run: `docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable --severity=warning deploy/server/*.sh deploy/server/tests/*.sh`
Expected: no output, exit code 0.

- [ ] **Step 10: Commit**

```bash
git add deploy/server/bootstrap.sh deploy/server/migrate-data.sh deploy/server/deploy.sh deploy/server/pull-backup.sh deploy/server/tests/server-scripts.test.sh
git commit -m "feat(deploy): add server bootstrap, data copy, deploy and backup scripts

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Image build workflow

**Files:**
- Create: `.github/workflows/build-image.yml`

**Interfaces:**
- Consumes: the repo `Dockerfile` (build args `NEXT_PUBLIC_WEBAPP_URL`, `NEXT_PUBLIC_LICENSE_CONSENT`, `CALCOM_TELEMETRY_DISABLED`, `DATABASE_URL`; runtime `scripts/start.sh` needs `DATABASE_HOST`, `DATABASE_URL`, `NEXTAUTH_SECRET`, `CALENDSO_ENCRYPTION_KEY`).
- Produces: `ghcr.io/3376016376joshua-oss/cal.diy:latest` (pushes to `main` and manual runs on `main`) and `:sha-<7 chars>` (every non-PR run), which Task 2's Compose file and Task 3's `deploy.sh` pull. Workflow name `Build image`, file name `build-image.yml` (the README's disable command filters on this path).

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/build-image.yml`:

```yaml
name: Build image

on:
  push:
    branches: [main]
  pull_request:
    paths:
      - Dockerfile
      - .github/workflows/build-image.yml
      - deploy/server/**
  workflow_dispatch:

permissions:
  contents: read
  packages: write

concurrency:
  group: build-image-${{ github.ref }}
  cancel-in-progress: true

env:
  POSTGRES_USER: calcom
  POSTGRES_PASSWORD: build-only-password
  POSTGRES_DB: calendso

jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 90
    steps:
      - uses: actions/checkout@v4

      # next build inlines NEXT_PUBLIC_* values, so they cannot come from the server .env.
      # The website URL uses the webapp placeholder so the Dockerfile and scripts/start.sh rewrite it to the real domain.
      - name: Write build-time public settings
        run: |
          cat > apps/web/.env.production <<'EOF'
          NEXT_PUBLIC_DISABLE_SIGNUP=true
          NEXT_PUBLIC_WEBSITE_URL=http://NEXT_PUBLIC_WEBAPP_URL_PLACEHOLDER
          EOF

      # Same approach as .github/actions/docker-build-and-test: the build gets a live, empty Postgres.
      - name: Start build database
        run: |
          docker network create ci
          docker run -d --name database --network ci \
            -e POSTGRES_USER -e POSTGRES_PASSWORD -e POSTGRES_DB \
            postgres:18
          until docker exec database pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"; do sleep 2; done

      - uses: docker/setup-buildx-action@v3
        with:
          driver-opts: network=container:database

      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - id: meta
        uses: docker/metadata-action@v5
        with:
          images: ghcr.io/${{ github.repository }}
          tags: |
            type=raw,value=latest,enable={{is_default_branch}}
            type=sha,format=short,prefix=sha-

      - name: Build image
        uses: docker/build-push-action@v6
        with:
          context: .
          file: Dockerfile
          platforms: linux/amd64
          load: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          build-args: |
            NEXT_PUBLIC_WEBAPP_URL=http://localhost:3000
            NEXT_PUBLIC_LICENSE_CONSENT=agree
            CALCOM_TELEMETRY_DISABLED=1
            DATABASE_URL=postgresql://${{ env.POSTGRES_USER }}:${{ env.POSTGRES_PASSWORD }}@localhost:5432/${{ env.POSTGRES_DB }}

      - name: Smoke test image
        env:
          TAGS: ${{ steps.meta.outputs.tags }}
        run: |
          image="$(head -n1 <<< "$TAGS")"
          db_url="postgresql://$POSTGRES_USER:$POSTGRES_PASSWORD@database:5432/$POSTGRES_DB"
          docker run -d --name calcom --network ci -p 3000:3000 \
            -e DATABASE_HOST=database:5432 \
            -e DATABASE_URL="$db_url" \
            -e DATABASE_DIRECT_URL="$db_url" \
            -e NEXTAUTH_SECRET=ci-only-auth-secret \
            -e CALENDSO_ENCRYPTION_KEY=0123456789abcdef0123456789abcdef \
            "$image"
          for i in $(seq 1 90); do
            code="$(curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/auth/login || true)"
            if [ "$code" = "200" ]; then
              echo "Healthy after about $((i * 5)) seconds"
              exit 0
            fi
            sleep 5
          done
          echo "No HTTP 200 from /auth/login (last status: $code)"
          docker logs --tail 200 calcom
          exit 1

      - name: Push image
        if: github.event_name != 'pull_request'
        env:
          TAGS: ${{ steps.meta.outputs.tags }}
        run: |
          while read -r tag; do
            docker push "$tag"
          done <<< "$TAGS"
```

- [ ] **Step 2: Lint the workflow**

Run: `docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -color .github/workflows/build-image.yml`
Expected: no output, exit code 0. Fix anything it reports and rerun.

- [ ] **Step 3: Check the build-time settings file stays out of git**

Run: `git check-ignore -v apps/web/.env.production`
Expected: `.gitignore:41:.env.*	apps/web/.env.production` (the workflow creates it only on the runner).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/build-image.yml
git commit -m "ci: build, smoke-test and publish the Cal.diy image to GHCR

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Owner runbook

**Files:**
- Create: `deploy/server/README.md`

**Interfaces:**
- Consumes: script names and arguments from Tasks 1 to 3, workflow name and file from Task 4.
- Produces: the steps the owner follows in Tasks 6 and 7.

- [ ] **Step 1: Write the runbook**

Create `deploy/server/README.md`:

````markdown
# Self-hosted Cal.diy server

Runs Cal.diy at `https://cal.reynenmeeting.org` on one Ubuntu 24.04 VPS: Postgres 18, the Cal.diy image from GHCR, and a Cloudflare Tunnel. Only SSH is open on the server. Design: `docs/superpowers/specs/2026-10-31-self-host-deploy-design.md`.

| Script | Runs | Purpose |
|---|---|---|
| `make-env.sh <hostname>` | Mac | Creates `deploy/server/.env.server` (gitignored) from the repo `.env` |
| `bootstrap.sh <ssh-target>` | Mac → server | Installs Docker and the firewall, copies config, sets up daily backups. Safe to re-run |
| `migrate-data.sh <ssh-target> <keep-user-ids>` | Mac → server | One-time copy of your local database, keeping only the listed users |
| `deploy.sh <ssh-target> [tag]` | Mac → server | Pulls the image, restarts, waits for the site to answer |
| `pull-backup.sh <ssh-target>` | Mac ← server | Copies the newest backup to `~/cal-backups` |
| `tests/server-scripts.test.sh` | Mac | Checks the scripts without a server |

`<ssh-target>` is `root@<server-ip>`.

## One-time setup

### 1. GitHub

1. Enable Actions in the fork: open https://github.com/3376016376joshua-oss/cal.diy/actions and confirm.
2. Disable every workflow except **Build image**. The upstream workflows run on push, pull request or schedule and fail without Cal.com's secrets. With the GitHub CLI (`brew install gh`, then `gh auth login`):

   ```bash
   gh workflow list -R 3376016376joshua-oss/cal.diy --all --json path,state --jq '.[] | select(.state == "active" and .path != ".github/workflows/build-image.yml") | .path' | xargs -n1 basename | xargs -I{} gh workflow disable {} -R 3376016376joshua-oss/cal.diy
   ```

   Without the CLI: Actions tab → each workflow → "…" → Disable workflow.
3. After the first successful **Build image** run on `main`: open https://github.com/users/3376016376joshua-oss/packages/container/package/cal.diy → Package settings → Change visibility → Public. The image contains no secrets.

### 2. Server

Create a VPS with Ubuntu 24.04, x86_64 (amd64), at least 4 GB RAM, and your SSH public key (for example `~/.ssh/id_ed25519.pub`). Accept its host key once:

```bash
ssh -o StrictHostKeyChecking=accept-new root@<server-ip> 'uname -m; . /etc/os-release; echo "$PRETTY_NAME"'
```

Expected: `x86_64` and `Ubuntu 24.04…`.

### 3. Cloudflare Tunnel

1. Cloudflare dashboard → Zero Trust → Networks → Tunnels → Create a tunnel → Cloudflared → name it `cal`.
2. Copy the token (the long value after `--token` in the install command). Don't run the install command: the server runs cloudflared in Docker.
3. Add a public hostname: subdomain `cal`, domain `reynenmeeting.org`, service type `HTTP`, URL `calcom:3000`.

### 4. Server env file

```bash
deploy/server/make-env.sh cal.reynenmeeting.org
```

Open `deploy/server/.env.server` and paste the tunnel token after `TUNNEL_TOKEN=`. This file holds your secrets; it is gitignored, never commit it.

### 5. Google Cloud Console

APIs & Services → Credentials → your OAuth client:

- Authorized JavaScript origins: add `https://cal.reynenmeeting.org`
- Authorized redirect URIs: add `https://cal.reynenmeeting.org/api/integrations/googlecalendar/callback`

OAuth consent screen: if the publishing status is "Testing", publish the app. Google expires refresh tokens of testing apps after 7 days, which would disconnect your calendar every week.

### 6. Install, copy data, start

```bash
deploy/server/bootstrap.sh root@<server-ip>
```

```bash
deploy/server/migrate-data.sh root@<server-ip> 42,43
```

```bash
deploy/server/deploy.sh root@<server-ip>
```

`42,43` are the accounts to keep (`3376016376joshua-gmail.com` and `reynen`). Every other account in the local database is a seed account with a known password and is deleted on the server.

### 7. Admin account

`reynen` is an ADMIN. In production an admin without a strong password (15+ characters with upper case, lower case and a number) and two-factor authentication is treated as an inactive admin. Set both under Settings → Security.

## Everyday use

### Book a meeting with guests

1. Sign in at https://cal.reynenmeeting.org.
2. Open your booking page, for example `https://cal.reynenmeeting.org/<username>/<event-slug>`.
3. Pick a time. Replace Name and Email with the main person's, and use "Add guests" for everyone else.
4. Confirm. Everyone gets the invitation email and the calendar invite.

### Update the app

Push or merge to `main`. When the **Build image** run finishes:

```bash
deploy/server/deploy.sh root@<server-ip>
```

### Roll back

Use the `sha-…` tag of an earlier build (listed on the package page):

```bash
deploy/server/deploy.sh root@<server-ip> sha-1a2b3c4
```

The next plain `deploy.sh` goes back to `latest`.

### Change a setting

Edit `deploy/server/.env.server`, then:

```bash
scp deploy/server/.env.server root@<server-ip>:/opt/cal/.env
```

```bash
deploy/server/deploy.sh root@<server-ip>
```

Settings that start with `NEXT_PUBLIC_` are built into the image. Change them in `.github/workflows/build-image.yml` ("Write build-time public settings") instead.

### Backups

The server saves `/opt/cal/backups/cal-<date>.dump` daily at 03:00 server time and keeps 7 days. Make one now and copy the newest to your Mac:

```bash
ssh root@<server-ip> /opt/cal/backup.sh
```

```bash
deploy/server/pull-backup.sh root@<server-ip>
```

To restore a dump (replaces the data on the server), sign in to the server and run:

```bash
cd /opt/cal
docker compose stop calcom
docker compose exec -T database sh -c 'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --no-owner --no-privileges' < backups/cal-<date>.dump
docker compose start calcom
```

## Troubleshooting

- `deploy.sh` reports not healthy: it prints the last 100 app log lines. For more: `ssh root@<server-ip> 'cd /opt/cal && docker compose logs --tail 300 calcom cloudflared'`.
- `docker compose pull` fails with "denied": the GHCR package is still private (GitHub step 3).
- To redo the data import from scratch, first delete the server database. **This deletes all data on the server:** `ssh root@<server-ip> 'cd /opt/cal && docker compose down -v'`. Then run `migrate-data.sh` and `deploy.sh` again.
````

- [ ] **Step 2: Check every script named in the runbook exists**

Run: `for s in make-env bootstrap migrate-data deploy pull-backup; do test -x "deploy/server/$s.sh" && echo "ok $s" || echo "MISSING $s"; done`
Expected: five `ok` lines.

- [ ] **Step 3: Commit**

```bash
git add deploy/server/README.md
git commit -m "docs(deploy): add the server runbook

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Pre-push checks, push, draft PR, CI

**Files:** none changed.

**Interfaces:**
- Consumes: Tasks 1 to 5 committed on `feat/self-host-deploy`; owner has done README "GitHub" steps 1 and 2.
- Produces: a draft PR into `3376016376joshua-oss/cal.diy` `main` with a green **Build image** run (build and smoke test, no push).

- [ ] **Step 1: Run all local checks**

```bash
deploy/server/tests/server-scripts.test.sh
```

Expected: `All checks passed`.

```bash
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable --severity=warning deploy/server/*.sh deploy/server/tests/*.sh
```

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -color .github/workflows/build-image.yml
```

Expected: both print nothing and exit 0.

- [ ] **Step 2: Run the repo type check (CLAUDE.md requires it before pushing)**

Run in the background, it takes several minutes: `yarn type-check:ci --force`
Expected: the same result as on `main`. This branch changes no TypeScript, so any error also exists on `main`; confirm with `git stash` / `git checkout main` per `agents/rules/ci-type-check-first.md` if it fails.

- [ ] **Step 3: Confirm the branch contents**

Run: `git diff --stat main...HEAD`
Expected: only `.github/workflows/build-image.yml`, `.gitignore`, `deploy/server/*` (8 files plus `tests/server-scripts.test.sh`) and the two `docs/superpowers/` files. `apps/web/next.config.ts` and `.claude/launch.json` must not appear.

- [ ] **Step 4: Confirm owner prerequisites, then ask to push**

Ask the owner to confirm README "GitHub" steps 1 and 2 are done, so the push does not start upstream workflows. Then ask for approval to push. Only after a clear yes:

```bash
git push -u origin feat/self-host-deploy
```

- [ ] **Step 5: Open the draft PR in the fork**

With the GitHub CLI (it targets upstream by default in a fork, so `-R` and `--base` are required):

```bash
gh pr create -R 3376016376joshua-oss/cal.diy --base main --head feat/self-host-deploy --draft --title "feat(deploy): self-hosted server with GHCR image and Cloudflare tunnel" --body "Adds a GitHub Actions image build (GHCR), a server compose stack (Postgres 18, Cal.diy, cloudflared) and scripts to set up the server, copy data, deploy and back up. Spec: docs/superpowers/specs/2026-10-31-self-host-deploy-design.md. Plan: docs/superpowers/plans/2026-10-31-self-host-deploy.md.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

Without the CLI, the owner opens https://github.com/3376016376joshua-oss/cal.diy/compare/main...feat/self-host-deploy?expand=1 and creates it as a draft with the same title and body.

- [ ] **Step 6: Watch the PR's Build image run**

Expected: the run takes roughly 20 to 45 minutes, "Smoke test image" prints `Healthy after about N seconds`, and "Push image" is skipped. If it fails, read the step log, fix on the branch, commit, and push again (with approval).

---

### Task 7: Go live and verify

**Files:** none in the repo. Creates `deploy/server/.env.server` (gitignored) and the server state.

**Interfaces:**
- Consumes: everything above; the owner's VPS IP, Cloudflare tunnel token and Google Console changes.
- Produces: `https://cal.reynenmeeting.org` serving the owner's accounts 42 and 43.

- [ ] **Step 1: Owner merges and the image is published**

The owner marks the PR ready and merges it. The **Build image** run on `main` must push `latest` and `sha-…`. Then the owner makes the package public (README GitHub step 3). Check anonymous access:

Run: `docker logout ghcr.io >/dev/null 2>&1; docker manifest inspect ghcr.io/3376016376joshua-oss/cal.diy:latest | head -5`
Expected: JSON starting with `{` and a `"schemaVersion"` line; `unauthorized` or `denied` means the package is still private.

- [ ] **Step 2: Owner creates the VPS, Cloudflare tunnel and Google changes**

README steps 2, 3 and 5. Ask the owner for the server IP. Then:

Run: `ssh -o StrictHostKeyChecking=accept-new root@<server-ip> 'uname -m; . /etc/os-release; echo "$PRETTY_NAME"; free -g | awk "/Mem/ {print \$2\" GB\"}"'`
Expected: `x86_64`, `Ubuntu 24.04…`, and at least `3 GB` (a 4 GB plan reports 3).

- [ ] **Step 3: Generate the server env**

Run: `deploy/server/make-env.sh cal.reynenmeeting.org`
Expected: `Wrote …/deploy/server/.env.server. Next: paste the Cloudflare tunnel token after TUNNEL_TOKEN=.`
The owner pastes the token into the file. Don't print the file.
Check without showing values: `grep -c '^TUNNEL_TOKEN=.\+' deploy/server/.env.server`, expected `1`.

- [ ] **Step 4: Bootstrap the server**

Run: `deploy/server/bootstrap.sh root@<server-ip>`
Expected: apt output, `Rules updated`, `Firewall is active and enabled on system startup`, then `Server ready. Next: …`.
Check: `ssh root@<server-ip> 'ufw status | head -5; docker compose version; ls -l /opt/cal'` shows only `OpenSSH` allowed, a Compose v2 version, and `.env` with `-rw-------`.

- [ ] **Step 5: Copy the data**

Run: `deploy/server/migrate-data.sh root@<server-ip> 42,43`
Expected: a dump size, then `Users on the server now:` listing exactly `42|3376016376joshua-gmail.com` and `43|reynen`, then `Data copied. Next: …`.

- [ ] **Step 6: Deploy**

Run: `deploy/server/deploy.sh root@<server-ip>`
Expected: pull output, then `Healthy: https://cal.reynenmeeting.org/auth/login` within 5 minutes.

- [ ] **Step 7: Verify sign-up is disabled and nothing else is exposed**

Run: `curl -s -o /dev/null -w '%{http_code}\n' -X POST https://cal.reynenmeeting.org/api/auth/signup -H 'content-type: application/json' -d '{}'`
Expected: `403`.

Run: `nc -z -w 3 <server-ip> 5432; echo "postgres reachable: $?"; nc -z -w 3 <server-ip> 3000; echo "app port reachable: $?"`
Expected: both report `1` (not reachable).

- [ ] **Step 8: Verify in the browser**

Open `https://cal.reynenmeeting.org/auth/login` in the browser pane. The owner signs in (Claude never types production passwords). Confirm the event types of account 42 are listed and Settings → Calendars shows Google Calendar connected. Take a screenshot as proof.

- [ ] **Step 9: Owner books a test meeting with a guest**

The owner opens their own booking page, picks a slot, enters a second address they control as the main person, and adds a third as a guest. Expected: the invitee, the guest and the organizer each receive an email, and the event appears in Google Calendar with both attendees.

- [ ] **Step 10: Verify backups**

Run: `ssh root@<server-ip> /opt/cal/backup.sh`
Expected: `Saved /opt/cal/backups/cal-<today>.dump`.

Run: `deploy/server/pull-backup.sh root@<server-ip>`
Expected: `Saved /Users/weijun/cal-backups/cal-<today>.dump`.

- [ ] **Step 11: Owner secures the admin account**

README step 7: strong password and 2FA for `reynen`.
