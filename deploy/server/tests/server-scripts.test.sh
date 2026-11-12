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
check "migrate-data needs users to keep" guard "usage: migrate-data.sh" "$server_dir/migrate-data.sh" root@192.0.2.1
check "migrate-data rejects a malformed user list" guard "comma-separated list" "$server_dir/migrate-data.sh" root@192.0.2.1 "42;43"
check "deploy needs a target" guard "usage: deploy.sh" "$server_dir/deploy.sh"
check "deploy rejects an unsafe image tag" guard "Invalid image tag" env CAL_ENV_FILE="$out" "$server_dir/deploy.sh" root@192.0.2.1 'latest;reboot'
check "pull-backup needs a target" guard "usage: pull-backup.sh" "$server_dir/pull-backup.sh"
for script in bootstrap.sh migrate-data.sh deploy.sh pull-backup.sh make-env.sh; do
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
check "migrate-data.sh server script has valid syntax" body_has_valid_syntax bash migrate-data.sh REMOTE
check "deploy.sh server script has valid syntax" body_has_valid_syntax bash deploy.sh REMOTE

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

# <tables already in the server database> <"abc123" if the app container exists, "" if not, "fail" if Compose cannot say>
#   [users outside the keep list, or "fail" if they cannot be counted; default 0] [1 if deploy.sh has already written the live marker]
#   [a docker call that fails, as text from its arguments] [users to keep that exist, or "fail" if they cannot be counted; default 2]
#   [1 if an earlier import left .imported on the server]
migrate_against_fake() {
  : > "$docker_log"
  rm -f "$fake_root/.deployed" "$fake_root/.imported" "$fake_root/backups/initial-import.dump"
  if [ -n "${4:-}" ]; then
    echo "2026-10-31T12:00:00Z" > "$fake_root/.deployed"
  fi
  if [ -n "${7:-}" ]; then
    echo "2020-01-01T00:00:00Z" > "$fake_root/.imported"
  fi
  run_capture env PATH="$fakes:$PATH" DOCKER_LOG="$docker_log" FAKE_OPT_CAL="$fake_root" FAKE_TABLES="$1" FAKE_APP_CONTAINER="$2" FAKE_USER_COUNT="${6:-2}" \
    FAKE_OTHER_USERS="${3:-0}" FAKE_DOCKER_FAIL="${5:-}" LOCAL_DB_CONTAINER=fake-local-db "$server_dir/migrate-data.sh" root@192.0.2.1 42,43
}

show_migrate_run() {
  echo "  exit status $last_status"
  sed 's/^/  stderr: /' "$work/stderr"
  sed 's/^/  docker: /' "$docker_log"
}

# <app container> <users outside the keep list>
migrate_refuses_to_reset() {
  migrate_against_fake 12 "$1" "$2"
  if [ "$last_status" -eq 1 ] && grep -qF "must NOT be reset" "$work/stderr" && grep -qF "restore a backup" "$work/stderr" \
    && ! grep -qF "down -v" "$work/stderr" && ! grep -qF "pg_restore" "$docker_log"; then
    return 0
  fi
  show_migrate_run
  return 1
}

migrate_offers_reset_before_the_purge() {
  migrate_against_fake 12 "" 3
  if [ "$last_status" -eq 1 ] && grep -qF "down -v" "$work/stderr" && grep -qF "deletes all server data" "$work/stderr" \
    && ! grep -qF "must NOT be reset" "$work/stderr" && ! grep -qF "pg_restore" "$docker_log"; then
    return 0
  fi
  show_migrate_run
  return 1
}

migrate_refuses_after_go_live() {
  migrate_against_fake 0 "" 0 1
  if [ "$last_status" -eq 1 ] && grep -qF "already started the app" "$work/stderr" && grep -qF "restore a backup" "$work/stderr" \
    && ! grep -qE 'pg_dump|^docker exec ' "$docker_log" && [ ! -e "$fake_root/backups/initial-import.dump" ]; then
    return 0
  fi
  show_migrate_run
  return 1
}

# The Mac-side check normally stops first, so run the server script directly to see its own last line of defence.
migrate_server_script_checks_the_marker_too() {
  : > "$docker_log"
  heredoc_body "$server_dir/migrate-data.sh" REMOTE > "$work/migrate-remote.sh"
  echo "2026-10-31T12:00:00Z" > "$fake_root/.deployed"
  run_capture env PATH="$fakes:$PATH" DOCKER_LOG="$docker_log" FAKE_OPT_CAL="$fake_root" FAKE_TABLES=12 FAKE_APP_CONTAINER="" FAKE_USER_COUNT=2 FAKE_OTHER_USERS=3 \
    "$fakes/ssh" root@192.0.2.1 "KEEP_USER_IDS='42,43' bash -s" < "$work/migrate-remote.sh"
  rm -f "$fake_root/.deployed"
  if [ "$last_status" -eq 1 ] && grep -qF "must NOT be reset" "$work/stderr" && ! grep -qF "down -v" "$work/stderr"; then
    return 0
  fi
  show_migrate_run
  return 1
}

migrate_stops_when_ssh_fails() {
  : > "$stub_log"
  run_capture env PATH="$stubs:$PATH" "$server_dir/migrate-data.sh" root@192.0.2.1 42,43
  if [ "$last_status" -eq 1 ] && grep -qF "Could not reach" "$work/stderr" && [ "$(grep -c . "$stub_log")" -eq 1 ] && grep -q '^ssh ' "$stub_log"; then
    return 0
  fi
  echo "  exit status $last_status"
  sed 's/^/  stderr: /' "$work/stderr"
  sed 's/^/  stub: /' "$stub_log"
  return 1
}

migrate_marks_the_import_finished() {
  migrate_against_fake 0 "" 0 "" "" 2 1
  if [ "$last_status" -eq 0 ] && grep -qF "delete from users" "$docker_log" \
    && grep -qxE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' "$fake_root/.imported" \
    && ! grep -qx '2020-01-01T00:00:00Z' "$fake_root/.imported"; then
    return 0
  fi
  show_migrate_run
  return 1
}

# An earlier import's .imported is on the server and the database was reset, so only this run can leave a marker.
# <message the script must print, or "" for none> <docker call that fails> <users to keep that exist> <text in the docker log that shows the script got that far>
migrate_import_leaves_no_marker() {
  migrate_against_fake 0 "" 0 "" "$2" "$3" 1
  if [ "$last_status" -eq 1 ] && { [ -z "$1" ] || grep -qF "$1" "$work/stderr"; } && grep -qF "$4" "$docker_log" && [ ! -e "$fake_root/.imported" ]; then
    return 0
  fi
  show_migrate_run
  echo "  .imported exists: $([ -e "$fake_root/.imported" ] && echo yes || echo no)"
  return 1
}

check "migrate-data refuses once deploy.sh has started the app, before dumping anything" migrate_refuses_after_go_live
check "migrate-data's server script also stops on the live marker" migrate_server_script_checks_the_marker_too
check "migrate-data stops when it cannot ask the server" migrate_stops_when_ssh_fails
check "migrate-data says do not reset once the app container exists" migrate_refuses_to_reset abc123 3
check "migrate-data says do not reset when Compose cannot tell" migrate_refuses_to_reset fail 3
check "migrate-data says do not reset after the purge, with no container left" migrate_refuses_to_reset "" 0
check "migrate-data says do not reset when the other users cannot be counted" migrate_refuses_to_reset "" fail
check "migrate-data offers the reset only while seed accounts remain and the app never ran" migrate_offers_reset_before_the_purge
check "migrate-data writes .imported (a fresh UTC time) once the other users are deleted" migrate_marks_the_import_finished
check "migrate-data leaves no .imported, old ones included, when the users to keep are not all there" migrate_import_leaves_no_marker "Only 1 of the 2 users to keep exist" "" 1 "where id in (42,43)"
check "migrate-data leaves no .imported when the users to keep cannot be counted" migrate_import_leaves_no_marker "Could not count the users to keep" "" fail "where id in (42,43)"
check "migrate-data leaves no .imported when deleting the other users fails" migrate_import_leaves_no_marker "Deleting the other users failed" "delete from users" 2 "delete from users"
check "migrate-data leaves no .imported when the restore fails" migrate_import_leaves_no_marker "" "pg_restore" 2 "pg_restore"

# <markers the server already has: "imported" and/or "deployed"; none for a server where migrate-data.sh has not finished>
fake_server_has() {
  rm -f "$fake_root/.imported" "$fake_root/.deployed"
  for marker in "$@"; do
    echo "2026-10-31T12:00:00Z" > "$fake_root/.$marker"
  done
}

# <user count the database reports, or "fail"> [image tag] [a docker call that fails, as text from its arguments]
deploy_against_fake() {
  : > "$docker_log"
  run_capture env PATH="$fakes:$PATH" DOCKER_LOG="$docker_log" FAKE_OPT_CAL="$fake_root" FAKE_USER_COUNT="$1" FAKE_DOCKER_FAIL="${3:-}" CAL_ENV_FILE="$out" \
    "$server_dir/deploy.sh" root@192.0.2.1 ${2:+"$2"}
}

show_deploy_run() {
  echo "  exit status $last_status"
  sed 's/^/  stderr: /' "$work/stderr"
  sed 's/^/  docker: /' "$docker_log"
}

deploy_refuses_before_the_import_has_finished() {
  fake_server_has
  deploy_against_fake 2
  if [ "$last_status" -eq 1 ] \
    && grep -qF "The data import has not finished" "$work/stderr" \
    && grep -qF "migrate-data.sh <ssh-target> 42,43" "$work/stderr" \
    && grep -qF "ssh <ssh-target> touch " "$work/stderr" \
    && [ ! -s "$docker_log" ] \
    && [ ! -e "$fake_root/.deployed" ]; then
    return 0
  fi
  show_deploy_run
  return 1
}

# <markers the server has: "imported" or "deployed">
deploy_starts_app_with_marker() {
  fake_server_has "$1"
  deploy_against_fake 2
  if [ "$last_status" -eq 0 ] \
    && grep -qF "compose pull" "$docker_log" \
    && grep -qF "compose up -d --remove-orphans" "$docker_log"; then
    return 0
  fi
  show_deploy_run
  return 1
}

deploy_refuses_empty_database() {
  fake_server_has imported
  deploy_against_fake "$1"
  if [ "$last_status" -eq 1 ] \
    && grep -qF "has no accounts" "$work/stderr" \
    && grep -qF "compose up -d --wait database" "$docker_log" \
    && ! grep -qE 'compose (pull|up -d --remove-orphans)' "$docker_log" \
    && [ ! -e "$fake_root/.deployed" ]; then
    return 0
  fi
  show_deploy_run
  return 1
}

deploy_starts_app_with_accounts() {
  fake_server_has imported
  deploy_against_fake 2 sha-1a2b3c4
  if [ "$last_status" -eq 0 ] \
    && grep -qF "compose pull [tag=sha-1a2b3c4]" "$docker_log" \
    && grep -qF "compose up -d --remove-orphans [tag=sha-1a2b3c4]" "$docker_log" \
    && grep -qF "image prune -f" "$docker_log"; then
    return 0
  fi
  show_deploy_run
  return 1
}

deploy_writes_the_live_marker() {
  fake_server_has imported
  deploy_against_fake 2
  if [ "$last_status" -eq 0 ] && grep -qxE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' "$fake_root/.deployed"; then
    return 0
  fi
  show_deploy_run
  return 1
}

deploy_keeps_the_first_marker() {
  fake_server_has imported
  echo "2026-01-01T00:00:00Z" > "$fake_root/.deployed"
  deploy_against_fake 2
  if [ "$last_status" -eq 0 ] && [ "$(cat "$fake_root/.deployed")" = "2026-01-01T00:00:00Z" ]; then
    return 0
  fi
  show_deploy_run
  return 1
}

# <a docker call that fails>
deploy_writes_no_marker_when_it_fails() {
  fake_server_has imported
  deploy_against_fake 2 "" "$1"
  if [ "$last_status" -eq 1 ] && grep -qF "$1" "$docker_log" && [ ! -e "$fake_root/.deployed" ]; then
    return 0
  fi
  show_deploy_run
  return 1
}

check "deploy does not start the app before the import has finished, even when the database has accounts" deploy_refuses_before_the_import_has_finished
check "deploy starts the app with only .imported (the import finished)" deploy_starts_app_with_marker imported
check "deploy starts the app with only .deployed (the site is already live)" deploy_starts_app_with_marker deployed
check "deploy does not start the app on a database with 0 users" deploy_refuses_empty_database 0
check "deploy does not start the app when the users cannot be counted" deploy_refuses_empty_database fail
check "deploy starts the app, with the tag, once the database has users" deploy_starts_app_with_accounts
check "deploy writes .deployed (a UTC time) after the app is up" deploy_writes_the_live_marker
check "deploy keeps the time of the first deploy in .deployed" deploy_keeps_the_first_marker
check "deploy writes no .deployed when the image pull fails" deploy_writes_no_marker_when_it_fails "compose pull"
check "deploy writes no .deployed when starting the app fails" deploy_writes_no_marker_when_it_fails "compose up -d --remove-orphans"

pull_backup_picks_newest_dump() {
  local dest="$work/pulled"
  touch -t 202610300300 "$fake_root/backups/cal-2026-10-30-030000.dump"
  touch -t 202610310300 "$fake_root/backups/cal-2026-10-31-030000.dump"
  touch -t 202610311415 "$fake_root/backups/cal-2026-10-31-141500.dump"
  touch -t 202610311500 "$fake_root/backups/cal-2026-10-31-150000.dump.partial"
  touch -t 202610311600 "$fake_root/backups/initial-import.dump"
  run_capture env PATH="$fakes:$PATH" FAKE_OPT_CAL="$fake_root" CAL_BACKUP_DIR="$dest" "$server_dir/pull-backup.sh" root@192.0.2.1
  [ "$last_status" -eq 0 ] && [ "$(ls "$dest")" = "cal-2026-10-31-141500.dump" ]
}

check "pull-backup picks the newest dated dump, not partial or import files" pull_backup_picks_newest_dump

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
