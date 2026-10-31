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

# Runs "$@", keeping its exit status in $last_status and its stderr in $work/stderr.
run_capture() {
  last_status=0
  "$@" >/dev/null 2>"$work/stderr" || last_status=$?
}

fails_with() {
  local expected="$1"
  shift
  run_capture "$@"
  [ "$last_status" -ne 0 ] && grep -qF -- "$expected" "$work/stderr"
}

# --- make-env.sh ---
cat > "$work/source.env" <<'EOF'
NEXT_PUBLIC_WEBAPP_URL='https://old-words.trycloudflare.com'
NEXT_PUBLIC_WEBSITE_URL='https://old-words.trycloudflare.com'
NEXTAUTH_URL='https://old-words.trycloudflare.com'
NEXT_PUBLIC_DISABLE_SIGNUP=
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
check "sign-up stays disabled whatever the source env says" test "$(grep -cx 'NEXT_PUBLIC_DISABLE_SIGNUP=true' "$out")" = 1
check "no other NEXT_PUBLIC_DISABLE_SIGNUP line" test "$(grep -c '^NEXT_PUBLIC_DISABLE_SIGNUP=' "$out")" = 1
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
check "make-env refuses to overwrite" fails_with "already exists" "$server_dir/make-env.sh" cal.example.com "$work/source.env" "$out"
check "make-env warns that a new file means a new database password" fails_with "only before the first deploy" "$server_dir/make-env.sh" cal.example.com "$work/source.env" "$out"
check "make-env rejects a bare word as hostname" fails_with "Hostname must look like" "$server_dir/make-env.sh" localhost "$work/source.env" "$work/other.env"

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
check "every service caps its log size" test "$(grep -cE '^ {8}max-size: 10m$' <<< "$config")" = 3

missing=""
for key in CAL_DOMAIN NEXT_PUBLIC_WEBAPP_URL NEXT_PUBLIC_DISABLE_SIGNUP NEXTAUTH_URL POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB DATABASE_URL DATABASE_DIRECT_URL TUNNEL_TOKEN; do
  grep -q "^$key=" "$server_dir/.env.server.example" 2>/dev/null || missing="$missing $key"
done
check "example env lists the generated keys${missing:+ (missing:$missing)}" test -z "$missing"
check "example env is tracked by git" refuses git -C "$server_dir" check-ignore -q .env.server.example
check "real env stays ignored by git" quiet git -C "$server_dir" check-ignore -q .env.server

# shellcheck disable=SC2043 # one script so far; the list grows in the later parts of the deploy
for script in make-env.sh; do
  check "$script is executable" test -x "$server_dir/$script"
  check "$script has valid bash syntax" bash -n "$server_dir/$script"
done

# --- summary ---
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All checks passed"
