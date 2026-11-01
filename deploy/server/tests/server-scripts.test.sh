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

# --- input guards (no server needed) ---
# Stand-ins for the tools that reach a network or Docker. Each logs its call and exits 99, so a guard
# that stops firing is caught: the script would reach a stub, leave a log line and exit 99.
stubs="$work/stubs"
stub_log="$work/stub.log"
mkdir -p "$stubs"
: > "$stub_log"
for tool in ssh scp docker curl; do
  cat > "$stubs/$tool" <<EOF
#!/bin/sh
echo "$tool \$*" >> "$stub_log"
exit 99
EOF
  chmod +x "$stubs/$tool"
done

# Passes only if the script refused on its own: non-zero exit other than a stub's 99, no stub call, and its own message.
guard() {
  local expected="$1"
  shift
  : > "$stub_log"
  run_capture env PATH="$stubs:$PATH" "$@"
  if [ "$last_status" -eq 0 ]; then
    echo "  the script exited 0"
    return 1
  fi
  if [ "$last_status" -eq 99 ] || [ -s "$stub_log" ]; then
    echo "  the script got past its guard and called a stubbed command:"
    sed 's/^/    /' "$stub_log"
    return 1
  fi
  if ! grep -qF -- "$expected" "$work/stderr"; then
    echo "  stderr does not mention: $expected"
    return 1
  fi
}

check "bootstrap needs a target" guard "usage: bootstrap.sh" "$server_dir/bootstrap.sh"
check "bootstrap refuses an empty tunnel token" guard "TUNNEL_TOKEN is empty" env CAL_ENV_FILE="$out" "$server_dir/bootstrap.sh" root@192.0.2.1
for script in bootstrap.sh make-env.sh; do
  check "$script is executable" test -x "$server_dir/$script"
  check "$script has valid bash syntax" bash -n "$server_dir/$script"
done

# --- remote scripts: syntax of the bodies that bash -n on the file cannot see ---
heredoc_body() {
  awk -v start="<<'$2'" -v end="$2" '$0 == end { found = 0 } found { print } index($0, start) { found = 1 }' "$1"
}

body_has_valid_syntax() {
  local shell="$1" file="$2" marker="$3"
  heredoc_body "$server_dir/$file" "$marker" > "$work/body.sh"
  [ -s "$work/body.sh" ] && "$shell" -n "$work/body.sh"
}

check "bootstrap.sh server script has valid syntax" body_has_valid_syntax bash bootstrap.sh REMOTE
check "backup.sh (written by bootstrap.sh) has valid syntax" body_has_valid_syntax sh bootstrap.sh BACKUP

# --- the scripts against a fake server ---
# The fake ssh runs the remote command locally with /opt/cal moved into $work, the fake docker answers the
# user count and logs its calls, and nothing here can reach a real host.
fakes="$work/fakes"
fake_root="$work/opt-cal"
docker_log="$work/docker.log"
ssh_log="$work/ssh.log"
export SSH_LOG="$ssh_log"
mkdir -p "$fakes" "$fake_root/backups"
# The fake ssh fails closed: it runs only the exact commands the scripts send and refuses everything else (exit 98,
# logged to $SSH_LOG so a script that swallows the failure still leaves a trace). Without that, a changed script
# could run an arbitrary command on this Mac.
cat > "$fakes/ssh" <<'EOF'
#!/bin/sh
: "${FAKE_OPT_CAL:?FAKE_OPT_CAL is not set}"
shift
cmd="$1"
refuse() {
  why="${1:-$cmd}"
  echo "refused: $why" >> "${SSH_LOG:-/dev/null}"
  echo "fake ssh refused to run: $why" >&2
  exit 98
}
local_cmd="$(printf '%s' "$cmd" | sed "s#/opt/cal#$FAKE_OPT_CAL#g")"
# A received script may name only the fake root and /dev/null as absolute paths, so a changed script cannot touch the rest of this Mac.
run_script() {
  body="$(sed "s#/opt/cal#$FAKE_OPT_CAL#g")"
  for path in $(printf '%s\n' "$body" | grep -oE '(^|[^A-Za-z0-9_-])/[A-Za-z0-9_./-]*' | sed 's/^[^/]*//'); do
    case "$path" in
      */../* | */..) refuse "$cmd (the script uses $path)" ;;
      /dev/null | "$FAKE_OPT_CAL" | "$FAKE_OPT_CAL"/*) ;;
      *) refuse "$cmd (the script uses $path)" ;;
    esac
  done
  printf '%s\n' "$body" | sh -c "$local_cmd"
}
case "$cmd" in
  "CAL_IMAGE_TAG='"*"' bash -s")
    value="${cmd#CAL_IMAGE_TAG=\'}"
    value="${value%\' bash -s}"
    case "$value" in "" | *[!A-Za-z0-9_.-]*) refuse ;; esac
    run_script
    ;;
  "KEEP_USER_IDS='"*"' bash -s")
    value="${cmd#KEEP_USER_IDS=\'}"
    value="${value%\' bash -s}"
    case "$value" in "" | *[!0-9,]*) refuse ;; esac
    run_script
    ;;
  # bootstrap.sh's root-only setup script (apt, ufw, cron) is read and thrown away, never run.
  "bash -s") cat > /dev/null ;;
  # The paths are printed as the real server prints them, so the fake scp is handed /opt/cal paths and can check them strictly.
  'ls -1t /opt/cal/backups/cal-*.dump 2>/dev/null | head -n1')
    sh -c "$local_cmd" </dev/null | sed "s#$FAKE_OPT_CAL#/opt/cal#g"
    ;;
  'test ! -e /opt/cal/.deployed' \
    | 'chmod 600 /opt/cal/.env' \
    | 'docker image prune -f' \
    | 'cd /opt/cal && docker compose config -q 2>&1' \
    | 'cd /opt/cal && docker compose logs --tail 100 calcom cloudflared' \
    | 'if [ -f /opt/cal/.env ]; then (umask 077; cp /opt/cal/.env "/opt/cal/.env.bak-$(date +%Y%m%d-%H%M%S)"); fi')
    sh -c "$local_cmd" </dev/null
    ;;
  *) refuse ;;
esac
EOF
cat > "$fakes/docker" <<'EOF'
#!/bin/sh
echo "docker $* [tag=${CAL_IMAGE_TAG:-}]" >> "$DOCKER_LOG"
if [ -n "${FAKE_DOCKER_FAIL:-}" ]; then
  case "$*" in *"$FAKE_DOCKER_FAIL"*) exit 1 ;; esac
fi
case "$*" in
  *"config -q"*) [ -n "${FAKE_COMPOSE_WARN:-}" ] && echo "$FAKE_COMPOSE_WARN" ;;
  *"from users where id not in"*)
    [ "${FAKE_OTHER_USERS:-0}" = "fail" ] && exit 1
    echo "${FAKE_OTHER_USERS:-0}"
    ;;
  *"count(*) from users"*)
    [ "$FAKE_USER_COUNT" = "fail" ] && exit 1
    echo "$FAKE_USER_COUNT"
    ;;
  *"from pg_tables"*) echo "${FAKE_TABLES:-0}" ;;
  *"ps -a -q calcom"*)
    [ "${FAKE_APP_CONTAINER:-}" = "fail" ] && exit 1
    echo "${FAKE_APP_CONTAINER:-}"
    ;;
esac
exit 0
EOF
cat > "$fakes/curl" <<'EOF'
#!/bin/sh
echo 200
EOF
cat > "$fakes/scp" <<'EOF'
#!/bin/sh
# Like the fake ssh, it fails closed: a remote path outside /opt/cal exits 98 and is logged to $SSH_LOG.
: "${FAKE_OPT_CAL:?FAKE_OPT_CAL is not set}"
refuse() {
  echo "refused: scp $*" >> "${SSH_LOG:-/dev/null}"
  echo "fake scp refused: $*" >&2
  exit 98
}
for arg in "$@"; do
  case "$arg" in
    *:*)
      case "${arg#*:}" in
        */../* | */..) refuse "$@" ;;
        /opt/cal | /opt/cal/*) ;;
        *) refuse "$@" ;;
      esac
      ;;
  esac
done
fix() {
  case "$1" in
    *:*) printf '%s' "${1#*:}" | sed "s#/opt/cal#$FAKE_OPT_CAL#g" ;;
    *) printf '%s' "$1" ;;
  esac
}
cp "$(fix "$1")" "$(fix "$2")"
EOF
chmod +x "$fakes"/*

# bootstrap.sh sends a root-only setup script (apt, ufw, cron) through ssh. The shared fake ssh discards it and only runs the short commands.
boot_fakes="$work/boot-fakes"
boot_root="$work/boot-opt-cal"
mkdir -p "$boot_fakes" "$boot_root"
cp "$fakes/docker" "$fakes/scp" "$fakes/ssh" "$boot_fakes/"
printf 'TUNNEL_TOKEN=tok\n' > "$work/bootstrap.env"

# [compose warning text]
bootstrap_against_fake() {
  : > "$docker_log"
  run_capture env PATH="$boot_fakes:$PATH" DOCKER_LOG="$docker_log" FAKE_OPT_CAL="$boot_root" FAKE_COMPOSE_WARN="${1:-}" CAL_ENV_FILE="$work/bootstrap.env" \
    "$server_dir/bootstrap.sh" root@192.0.2.1
}

mode_of() {
  stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"
}

bootstrap_copies_env_without_backup_at_first() {
  rm -f "$boot_root/.env" "$boot_root"/.env.bak-*
  bootstrap_against_fake
  [ "$last_status" -eq 0 ] && [ "$(mode_of "$boot_root/.env")" = 600 ] && grep -qx 'TUNNEL_TOKEN=tok' "$boot_root/.env" \
    && [ -f "$boot_root/docker-compose.yml" ] && ! ls "$boot_root"/.env.bak-* > /dev/null 2>&1
}

bootstrap_keeps_the_previous_env() {
  echo "OLD_VALUE=1" > "$boot_root/.env"
  chmod 644 "$boot_root/.env"
  bootstrap_against_fake
  local backups=("$boot_root"/.env.bak-*)
  [ "$last_status" -eq 0 ] && [ "${#backups[@]}" -eq 1 ] && grep -qx 'OLD_VALUE=1' "${backups[0]}" \
    && [ "$(mode_of "${backups[0]}")" = 600 ] && grep -qx 'TUNNEL_TOKEN=tok' "$boot_root/.env" && [ "$(mode_of "$boot_root/.env")" = 600 ]
}

bootstrap_stops_on_compose_problem() {
  bootstrap_against_fake 'WARN The "leaked-fragment" variable is not set.'
  if [ "$last_status" -eq 1 ] && grep -qF "Docker Compose reported a problem" "$work/stderr" && grep -qF "dollar sign" "$work/stderr" \
    && ! grep -qF "leaked-fragment" "$work/stderr"; then
    return 0
  fi
  echo "  exit status $last_status"
  sed 's/^/  stderr: /' "$work/stderr"
  return 1
}

backup_names_have_date_and_time() {
  local file
  heredoc_body "$server_dir/bootstrap.sh" BACKUP | grep '^file=' > "$work/file-line.sh" || return 1
  file="$(. "$work/file-line.sh" && echo "$file")"
  [[ "$file" =~ ^backups/cal-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}\.dump$ ]] || { echo "  got: $file"; return 1; }
}

check "bootstrap copies compose file and env (mode 600), no backup when there was no .env" bootstrap_copies_env_without_backup_at_first
check "bootstrap keeps the previous server .env as a mode 600 backup" bootstrap_keeps_the_previous_env
check "bootstrap stops, without echoing values, when Compose cannot read the env" bootstrap_stops_on_compose_problem
check "backup names carry the time, so two backups on one day differ" backup_names_have_date_and_time

# --- the fake ssh itself ---
# <remote command the fake must refuse, and which would create $work/ssh-ran if it ran>
fake_ssh_refuses() {
  rm -f "$work/ssh-ran" "$work/ssh-direct.log"
  run_capture env SSH_LOG="$work/ssh-direct.log" FAKE_OPT_CAL="$fake_root" "$fakes/ssh" root@192.0.2.1 "$1" </dev/null
  if [ "$last_status" -eq 98 ] && [ ! -e "$work/ssh-ran" ] && grep -qF "refused: $1" "$work/ssh-direct.log"; then
    return 0
  fi
  echo "  exit status $last_status (want 98); command ran: $([ -e "$work/ssh-ran" ] && echo yes || echo no)"
  return 1
}

# <script body sent with bash -s; it creates $fake_root/body-ran first, so that file shows whether it ran> <the path that must be named in the log>
fake_ssh_refuses_body() {
  rm -f "$fake_root/body-ran" "$work/ssh-direct.log"
  printf '%s\n' "$1" > "$work/body-in.sh"
  run_capture env SSH_LOG="$work/ssh-direct.log" FAKE_OPT_CAL="$fake_root" "$fakes/ssh" root@192.0.2.1 "KEEP_USER_IDS='42,43' bash -s" < "$work/body-in.sh"
  if [ "$last_status" -eq 98 ] && [ ! -e "$fake_root/body-ran" ] && grep -qF "refused: " "$work/ssh-direct.log" && grep -qF "$2" "$work/ssh-direct.log"; then
    return 0
  fi
  echo "  exit status $last_status (want 98); script ran: $([ -e "$fake_root/body-ran" ] && echo yes || echo no)"
  return 1
}

fake_ssh_runs_body_inside_the_fake_root() {
  rm -f "$fake_root/body-ran"
  printf '%s\n' 'cd /opt/cal && echo hi > /dev/null && touch body-ran </dev/null' > "$work/body-in.sh"
  run_capture env SSH_LOG="$work/ssh-direct.log" FAKE_OPT_CAL="$fake_root" "$fakes/ssh" root@192.0.2.1 "KEEP_USER_IDS='42,43' bash -s" < "$work/body-in.sh"
  [ "$last_status" -eq 0 ] && [ -e "$fake_root/body-ran" ]
}

# <remote path the fake scp must refuse, for an upload to it and a download from it; either would create a file under $work if it copied>
fake_scp_refuses() {
  rm -f "$work/scp-ran" "$work/scp-copy" "$work/ssh-direct.log"
  : > "$work/scp-src"
  run_capture env SSH_LOG="$work/ssh-direct.log" FAKE_OPT_CAL="$fake_root" "$fakes/scp" "$work/scp-src" "root@192.0.2.1:$1" </dev/null
  local upload_status="$last_status" uploaded=no
  [ -e "$work/scp-ran" ] && uploaded=yes
  : > "$work/scp-ran"
  run_capture env SSH_LOG="$work/ssh-direct.log" FAKE_OPT_CAL="$fake_root" "$fakes/scp" "root@192.0.2.1:$1" "$work/scp-copy" </dev/null
  if [ "$upload_status" -eq 98 ] && [ "$last_status" -eq 98 ] && [ "$uploaded" = no ] && [ ! -e "$work/scp-copy" ] \
    && [ "$(grep -c '^refused: scp ' "$work/ssh-direct.log")" -eq 2 ]; then
    return 0
  fi
  echo "  exit status: upload $upload_status, download $last_status (want 98 for both); upload copied: $uploaded; download copied: $([ -e "$work/scp-copy" ] && echo yes || echo no)"
  return 1
}

check "fake ssh refuses a command it does not know, and runs nothing" fake_ssh_refuses "touch $work/ssh-ran"
check "fake ssh refuses a script prefix that smuggles in a command" fake_ssh_refuses "CAL_IMAGE_TAG='x'; touch $work/ssh-ran; echo '' bash -s"
check "fake ssh refuses a script that names an absolute path outside the fake root, and runs nothing" fake_ssh_refuses_body 'cd /opt/cal && touch body-ran && cat /etc/passwd' /etc/passwd
check "fake ssh refuses a script that climbs out of the fake root, and runs nothing" fake_ssh_refuses_body 'touch /opt/cal/body-ran; cat /opt/cal/../secret' /../secret
check "fake ssh still runs a script that stays inside the fake root and /dev/null" fake_ssh_runs_body_inside_the_fake_root
check "fake scp refuses a remote path outside /opt/cal, and copies nothing" fake_scp_refuses "$work/scp-ran"
check "fake scp refuses a remote path that climbs out of /opt/cal, and copies nothing" fake_scp_refuses "/opt/cal/../scp-ran"
check "no script sent the fake ssh a command it refuses" test ! -s "$ssh_log"

# --- summary ---
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All checks passed"
