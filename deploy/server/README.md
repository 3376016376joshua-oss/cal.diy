# Self-hosted Cal.diy server

Runs Cal.diy at `https://cal.reynenmeeting.org` on one Ubuntu 24.04 VPS: Postgres 18, the Cal.diy image from GHCR, and a Cloudflare Tunnel. Only SSH is open on the server. Design: `docs/superpowers/specs/2026-10-31-self-host-deploy-design.md`.

| Script | Runs | Purpose |
|---|---|---|
| `make-env.sh <hostname>` | Mac | Creates `deploy/server/.env.server` (gitignored) from the repo `.env` |
| `bootstrap.sh <ssh-target>` | Mac → server | Installs Docker and the firewall, copies config (the old server `.env` is kept as `.env.bak-<time>`), sets up daily backups. Safe to re-run |
| `migrate-data.sh <ssh-target> <keep-user-ids>` | Mac → server | One-time copy of your local database, keeping only the listed users. Refuses once `deploy.sh` has run |
| `deploy.sh <ssh-target> [tag]` | Mac → server | Pulls the image, restarts, waits for the site to answer. Refuses to start the app while the database has no accounts |
| `pull-backup.sh <ssh-target>` | Mac ← server | Copies the newest backup to `~/cal-backups` |
| `tests/server-scripts.test.sh` | Mac | Checks the scripts without a server |

`<ssh-target>` is `root@<server-ip>`.

Replace `<server-ip>` and any other `<...>` value with the real value, without the angle brackets. zsh treats `<` and `>` as file redirection, so a copy that keeps them fails with errors such as `parse error near '>'` or `no such file or directory: server-ip`. For example, if the server IP is 203.0.113.25, the target is `root@203.0.113.25`. Run every command from the repo root (`cal.diy`), because the `deploy/server/...` paths are relative to it, except the ones you type on the server after `ssh root@<server-ip>`.

## One-time setup

### 1. GitHub

1. Enable Actions in the fork: open https://github.com/3376016376joshua-oss/cal.diy/actions and confirm.
2. Disable every workflow except **Build image**. The upstream workflows run on push, pull request or schedule and fail without Cal.com's secrets. With the GitHub CLI (`brew install gh`, then `gh auth login`):

   ```bash
   gh workflow list -L 100 -R 3376016376joshua-oss/cal.diy --all --json path,state --jq '.[] | select(.state == "active" and .path != ".github/workflows/build-image.yml") | .path' | xargs -n1 basename | xargs -I{} gh workflow disable {} -R 3376016376joshua-oss/cal.diy
   ```

   Without the CLI: Actions tab → each workflow → "…" → Disable workflow.

   Run this again after every merge of upstream changes, because workflows that are new upstream start enabled.
3. The image exists only after the pull request is merged to `main` and the **Build image** run on `main` has finished. After that first successful run, make the image downloadable by the server: open https://github.com/users/3376016376joshua-oss/packages/container/package/cal.diy → Package settings → Change visibility → Public. The image contains no secrets.

   To keep the package private instead, sign in to GHCR once on the server, with a GitHub personal access token (classic) that has only the `read:packages` scope:

   ```bash
   ssh -t root@<server-ip> docker login ghcr.io -u 3376016376joshua-oss
   ```

   Paste the token when it asks for the password. The server keeps it in `/root/.docker/config.json`.

### 2. Server

Create a VPS with Ubuntu 24.04, x86_64 (amd64), at least 4 GB RAM, and your SSH public key (for example `~/.ssh/id_ed25519.pub`). Accept its host key once:

```bash
ssh -o StrictHostKeyChecking=accept-new root@<server-ip> 'uname -m; . /etc/os-release; echo "$PRETTY_NAME"'
```

Expected: `x86_64` and `Ubuntu 24.04…`.

### 3. Cloudflare Tunnel

The domain `reynenmeeting.org` must show as **Active** in the Cloudflare dashboard (Websites) before you start; the tunnel's hostname does not work until then.

1. Cloudflare dashboard → Zero Trust → Networks → Tunnels → Create a tunnel → Cloudflared → name it `cal`.
2. Open the **Docker** tab of the install command and copy the token, the long value after `--token`. Don't run the install command: the server runs cloudflared in Docker.
3. Add a public hostname: subdomain `cal`, domain `reynenmeeting.org`, service type `HTTP`, URL `calcom:3000`.

### 4. Server env file

```bash
deploy/server/make-env.sh cal.reynenmeeting.org
```

Open `deploy/server/.env.server` and paste the tunnel token after `TUNNEL_TOKEN=`. This file holds your secrets; it is gitignored, never commit it. If a value contains a dollar sign, put it in single quotes or write each `$` as `$$`; otherwise Docker Compose reads it as a variable.

The script also writes `NEXT_PUBLIC_DISABLE_SIGNUP=true`, so the server env cannot switch sign-up back on.

### 5. Google Cloud Console

APIs & Services → Credentials → your OAuth client:

- Authorized JavaScript origins: add `https://cal.reynenmeeting.org`
- Authorized redirect URIs: add `https://cal.reynenmeeting.org/api/integrations/googlecalendar/callback`

OAuth consent screen: if the publishing status is "Testing", publish the app. Google expires refresh tokens of testing apps after 7 days, which would disconnect your calendar every week.

### 6. Harden both accounts

Do this on your Mac, before copying the data. `reynen` is an ADMIN, and in production an admin without a strong password (15+ characters with upper case, lower case and a number) and two-factor authentication is treated as an inactive admin. `3376016376joshua-gmail.com` is reachable from the internet in the same way, so give it the same protection.

In your local Cal.diy, sign in as each of the two accounts, `3376016376joshua-gmail.com` and `reynen`, and under Settings → Security:

1. Set a strong password: 15+ characters, upper and lower case, and a number.
2. Enable two-factor authentication, and keep the backup codes somewhere safe, such as a password manager.

`migrate-data.sh` copies the local database, so the server gets the new passwords and two-factor settings. The server uses the same `CALENDSO_ENCRYPTION_KEY` as your local `.env`, which is what keeps the two-factor secrets readable.

Optional: a self-hosted Cal.diy does not throttle login attempts, so add a Cloudflare rate-limiting rule for the login request. Cloudflare dashboard → `reynenmeeting.org` → Security → WAF → Rate limiting rules → Create rule (menu names change from time to time). Match requests whose URI Path equals `/api/auth/callback/credentials`, count them per IP address, for example 5 requests per 10 seconds, and choose the action Block. The free plan includes one rule.

### 7. Install, copy data, start

```bash
deploy/server/bootstrap.sh root@<server-ip>
```

Next, copy your data. Make sure Docker is running on your Mac and the local database container `prisma-postgres-1` is up, because the script copies from it.

```bash
deploy/server/migrate-data.sh root@<server-ip> 42,43
```

When the script finishes, its output lists the accounts left on the server after `Users on the server now:`. That list must show only `42|3376016376joshua-gmail.com` and `43|reynen`. If any other account is listed, stop and do not run `deploy.sh`.

`deploy.sh` pulls the image, which exists only after the pull request is merged to `main` and the **Build image** run on `main` has finished (GitHub step 3). It also refuses to start the app while the server database has no accounts, because the first-run setup page would let anyone create an admin.

```bash
deploy/server/deploy.sh root@<server-ip>
```

`42,43` are the accounts to keep (`3376016376joshua-gmail.com` and `reynen`). Every other account in the local database is a seed account with a known password and is deleted on the server.

When each command succeeds, its last line is:

- `bootstrap.sh`: `Server ready. Next: …`. Use `42,43` for `<keep-user-ids>` in that hint, not the literal text.
- `migrate-data.sh`: `Data copied. Next: …`, printed after the account list
- `deploy.sh`: `Healthy: https://cal.reynenmeeting.org/auth/login`

## Everyday use

### Book a meeting with guests

1. Sign in at https://cal.reynenmeeting.org.
2. Open your booking page, for example `https://cal.reynenmeeting.org/<username>/<event-slug>`.
3. Pick a time. Replace Name and Email with the main person's, and use "Add guests" for everyone else.
4. Confirm. Everyone gets the invitation email and the calendar invite.

Other people don't need an account to book you. Send them a link such as `https://cal.reynenmeeting.org/reynen/30min`, or `https://cal.reynenmeeting.org/reynen` for all your public event types; they pick a time, enter their name and email, and can add guests themselves. Turning off sign-up only stops new accounts from being created. If you want shorter links for `3376016376joshua-gmail.com`, change its username under Settings → My account → Profile before you share any links, because links with the old username stop working.

### Update the app

Make a backup first, so you can roll back:

```bash
ssh root@<server-ip> /opt/cal/backup.sh
```

Push or merge to `main`. When the **Build image** run on `main` finishes, run:

```bash
deploy/server/deploy.sh root@<server-ip>
```

If the update changed `deploy/server/docker-compose.yml`, run `deploy/server/bootstrap.sh root@<server-ip>` first. It copies the compose file to the server and is safe to re-run. If the update merged upstream changes, run the disable-workflows command from GitHub step 2 again.

### Roll back

The app applies database migrations on every start and never reverts them. So make a backup before each update (`ssh root@<server-ip> /opt/cal/backup.sh`). If the release you are leaving changed the database, first restore the dump from before that update, with steps 1 to 7 under "Restore a backup" below, then deploy the image tag that matches that dump (step 8 there).

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

Most settings that start with `NEXT_PUBLIC_` are built into the image. The exception is `NEXT_PUBLIC_WEBAPP_URL`: the container swaps the built-in address for the value in `.env` when it starts. Change the other `NEXT_PUBLIC_` settings in `.github/workflows/build-image.yml` ("Write build-time public settings") instead. Sign-up is switched off that way, and the **Build image** run fails unless `POST /api/auth/signup` answers 403 from the finished image.

### Backups

The server saves `/opt/cal/backups/cal-<date-time>.dump` daily at 03:00 server time, for example `cal-2026-10-31-030000.dump`, and keeps 7 days. Make one now and copy the newest to your Mac:

```bash
ssh root@<server-ip> /opt/cal/backup.sh
```

```bash
deploy/server/pull-backup.sh root@<server-ip>
```

#### Restore a backup

Once `deploy.sh` has run, a backup is the only way back to an earlier state: `migrate-data.sh` refuses from then on (see Troubleshooting). The app container is set to `restart: unless-stopped`, so after step 4 it stays stopped, even if Docker restarts, until `deploy.sh` starts it in step 8.

Sign in to the server. Run steps 1 to 7 there; step 8 runs on your Mac. Replace `<file>` with the dump's file name, for example `cal-2026-10-31-030000.dump`.

```bash
ssh root@<server-ip>
```

1. Go to the app folder:

   ```bash
   cd /opt/cal
   ```

2. List the backups and pick the file. Do this before step 3, so the dump that step 3 creates is not in the list:

   ```bash
   ls /opt/cal/backups
   ```

   If the dump is only on your Mac, copy it to the server first, by running this on the Mac in a second Terminal window or after typing `exit` to leave the server:

   ```bash
   scp ~/cal-backups/cal-<date-time>.dump root@<server-ip>:/opt/cal/backups/
   ```

3. Save the current state first:

   ```bash
   /opt/cal/backup.sh
   ```

4. Stop the app:

   ```bash
   docker compose stop calcom
   ```

**Step 5 deletes the whole server database. Everything saved since the dump you picked is lost; the backup from step 3 is the only copy of it.**

5. Replace the database with an empty one:

   ```bash
   docker compose exec -T database sh -c 'dropdb -U "$POSTGRES_USER" --force "$POSTGRES_DB" && createdb -U "$POSTGRES_USER" "$POSTGRES_DB"'
   ```

6. Load the dump:

   ```bash
   docker compose exec -T database sh -c 'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-privileges --single-transaction --exit-on-error' < backups/<file>
   ```

7. Check the accounts. Both `3376016376joshua-gmail.com` and `reynen` must be listed:

   ```bash
   docker compose exec -T database sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select id, username from users order by id"'
   ```

8. Back on the Mac, start the app. `deploy.sh` also refuses to start it if the restored database has no accounts:

   ```bash
   deploy/server/deploy.sh root@<server-ip>
   ```

   For a rollback, deploy the tag that matches the restored dump instead, for example `deploy/server/deploy.sh root@<server-ip> sha-1a2b3c4`. Starting a newer image on an older dump applies the newer image's database migrations to it again.

## Troubleshooting

- `deploy.sh` reports not healthy: it prints the last 100 app and tunnel log lines. For more: `ssh root@<server-ip> 'cd /opt/cal && docker compose logs --tail 300 calcom cloudflared'`.
- `deploy.sh` says the database has no accounts and did not start the app: on a first deploy run `migrate-data.sh`; on a live site restore a backup (Backups above).
- `deploy.sh` says the data import has not finished: it starts the app only after `/opt/cal/.imported` exists, which `migrate-data.sh` writes once it has removed the seed accounts (they have publicly known passwords). Run `migrate-data.sh` and check its account list; if it stopped with an error, redo the import as described under "To redo the data import" below. If you restored a backup onto a new server instead, mark the server yourself: `ssh root@<server-ip> touch /opt/cal/.imported`.
- `bootstrap.sh` stops with "Docker Compose reported a problem with /opt/cal/.env": most often a value in `deploy/server/.env.server` contains a dollar sign, which Compose reads as a variable. Put the value in single quotes or write each `$` as `$$`, then run `bootstrap.sh` again. The command it prints shows the messages, which can quote parts of the values.
- `docker compose pull` fails with "denied": the GHCR package is still private. Make it public (GitHub step 3) or run `docker login ghcr.io` on the server.
- `migrate-data.sh` says `deploy.sh` has already started the app: the first successful `deploy.sh` writes `/opt/cal/.deployed`, and `migrate-data.sh` refuses while that file exists, because the database may then hold bookings that exist nowhere else. To go back to an earlier state, restore a backup (Backups above). Only if this server has never served real bookings, for example after a test deploy, can you override it deliberately: `ssh root@<server-ip> rm /opt/cal/.deployed`, then do the reset in the next item.
- To redo the data import from scratch, delete the server database first, and do it only before the first deploy: **never after the site is live.** **This deletes all data on the server:** `ssh root@<server-ip> 'cd /opt/cal && docker compose down -v'`. Then run `migrate-data.sh` and `deploy.sh` again. Once the site is live, restore a backup instead (Backups above).
- `migrate-data.sh` says the database "must NOT be reset": the server database already holds an imported or live dataset, so the script refuses to touch it. Restore a backup instead (Backups above).
