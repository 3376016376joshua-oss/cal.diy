# Self-hosted deployment of Cal.diy: design

Date: 2026-10-31
Status: approved in brainstorming, waiting for spec review

## Goal

Run Cal.diy on an always-on server at a permanent HTTPS address (`https://cal.<domain>`), so the owner can:

1. Sign in to their own account.
2. Open their own booking page (for example `/<username>/30min`) and pick a free slot.
3. Enter the main invitee in Name/Email and add more people under "Add guests".
4. Confirm, after which Cal.diy emails everyone (Gmail SMTP) and creates the Google Calendar event.

Updating the server must take one command after a push to `main`.

## Non-goals

- No change to the booking flow or any app code. The existing booking page already supports host-entered attendees and guests (`packages/features/bookings/lib/getBookingFields.ts`, `packages/features/bookings/Booker/hooks/useInitialFormValues.ts`). Picking times outside the owner's availability stays out of scope.
- No API v2, Redis, Prisma Studio or reminder crons on the server.
- No automatic deploy from CI. Deploys stay a manual `deploy.sh` run.
- No changes to upstream files beyond one `.gitignore` line, so merges from `calcom/cal.diy` stay clean.

## Decisions

| Topic | Decision | Reason |
|---|---|---|
| Hosting | Always-on VPS, Ubuntu 24.04, amd64, 4 GB RAM | Reachable 24/7. amd64 is offered by almost every provider. |
| Image source | Built by GitHub Actions in the fork, published to GHCR | `calcom/cal.diy` on Docker Hub has no tags; `calcom/cal.com` is a different product with a different schema. The fork is public, so runners are free. |
| Address | Named Cloudflare Tunnel on a domain the owner buys and adds to Cloudflare | Permanent URL, HTTPS from Cloudflare, no inbound ports on the server. |
| Data | Move the local database to the server once | Keeps the account, event types, bookings and the Google Calendar connection. |
| Backups | Daily dump on the server, 7 kept, plus a pull script to the Mac | Data lives only on the server after the move. |
| Hostname | `cal.reynenmeeting.org` (domain bought 2026-10-31) | Leaves the bare domain free for other uses. |
| Accounts kept | User ids 42 (`3376016376joshua-gmail.com`) and 43 (`reynen`) | The other 41 local accounts are seed accounts with known passwords. |

## Architecture

```
git push (fork main)
   │
   ▼
GitHub Actions: build-image.yml ──► ghcr.io/3376016376joshua-oss/cal.diy:{latest, sha-<short>}
                                              │  docker compose pull (deploy.sh over SSH)
                                              ▼
guest browser ──► Cloudflare (cal.<domain>) ══ tunnel ══► VPS /opt/cal (docker compose, network "cal")
                                                            ├─ cloudflared  → http://calcom:3000
                                                            ├─ calcom       (GHCR image, no published port)
                                                            └─ database     (postgres:18, volume)
```

Only SSH (22) is open on the VPS (`ufw`). The app and database are reachable only inside the Docker network; the public path is the tunnel.

## Components (new files)

| File | Purpose |
|---|---|
| `.github/workflows/build-image.yml` | On push to `main`, on pull requests that touch deploy files, and on `workflow_dispatch`: write `apps/web/.env.production` with build-time public settings (see below), start a throwaway empty `postgres:18` attached to buildx the way upstream's `docker-build-and-test` action does, build `Dockerfile` for `linux/amd64`, smoke-test the image (`/auth/login` returns 200), and on non-PR runs push to GHCR as `latest` and `sha-<short>`. Logs in with `GITHUB_TOKEN` (`packages: write`). Passes no real secrets. |
| `deploy/server/make-env.sh <hostname>` | Generates the gitignored `deploy/server/.env.server` from the repo's `.env` (see "Server `.env` contents"), mode 600. Refuses to overwrite. |
| `deploy/server/tests/server-scripts.test.sh` | Runs without a server: checks `make-env.sh` output, that Compose parses the generated env, and the input guards of every script. |
| `deploy/server/docker-compose.yml` | Services `database` (`postgres:18`, named volume, `restart: always`), `calcom` (`ghcr.io/...:${CAL_IMAGE_TAG:-latest}`, `env_file: .env`, `DATABASE_HOST=database:5432`, no `ports:`), `cloudflared` (`cloudflare/cloudflared`, `tunnel run` with `TUNNEL_TOKEN` from `.env`). |
| `deploy/server/.env.server.example` | All keys the server needs, no values: `NEXT_PUBLIC_WEBAPP_URL`, `NEXTAUTH_URL`, `NEXTAUTH_SECRET`, `CALENDSO_ENCRYPTION_KEY`, `POSTGRES_*`, `DATABASE_URL`, `EMAIL_*`, `GOOGLE_API_CREDENTIALS`, `TUNNEL_TOKEN`, `CAL_DOMAIN`. |
| `deploy/server/bootstrap.sh <host>` | First-time setup over SSH: install `docker.io` and `docker-compose-v2` from Ubuntu's packages, `ufw allow OpenSSH` + enable, create `/opt/cal` and `/opt/cal/backups`, copy `docker-compose.yml` and `.env.server` (as `/opt/cal/.env`, mode 600), install the backup cron entry. Safe to re-run. |
| `deploy/server/migrate-data.sh <host> <keep-user-ids>` | One time: `pg_dump -Fc` from local container `prisma-postgres-1`, `scp` to the server, start only `database`, `pg_restore --no-owner --single-transaction` into it, then delete every user not in `<keep-user-ids>` (the local database holds 41 seed accounts with publicly known passwords). Refuses to run if the server database already has tables, and deletes nothing unless every id to keep exists. The app is started by `deploy.sh`, not here. |
| `deploy/server/deploy.sh <host> [tag]` | `docker compose pull && docker compose up -d` on the server, then poll `https://$CAL_DOMAIN/auth/login` for HTTP 200 (up to 5 minutes). `CAL_DOMAIN` is read from the local `deploy/server/.env.server`. On failure, print the last 100 lines of `calcom` logs and exit non-zero. An optional tag pins an older image for rollback. |
| `deploy/server/pull-backup.sh <host>` | Copy the newest dump from `/opt/cal/backups/` to `~/cal-backups/` on the Mac. |
| `deploy/server/README.md` | Step-by-step runbook covering the owner's manual steps and the script order. |
| `.gitignore` (one line) | `!deploy/server/.env.server.example`, because `.env.*` ignores it otherwise. The real `deploy/server/.env.server` stays ignored. |

Backup (installed by `bootstrap.sh`): `/opt/cal/backup.sh` dumps with `docker compose exec -T database pg_dump -Fc` to `/opt/cal/backups/cal-<date>.dump` and keeps 7 days; `/etc/cron.d/cal-backup` runs it daily at 03:00 server time. It can also be run by hand.

### Build-time public settings

`next build` inlines every `process.env.NEXT_PUBLIC_*` value, so these cannot come from the server `.env`. The workflow writes `apps/web/.env.production` (gitignored, read by Next.js automatically, not excluded by `.dockerignore`) before building:

- `NEXT_PUBLIC_DISABLE_SIGNUP=true`, so strangers cannot create accounts (`apps/web/app/api/auth/signup/route.ts` returns 403).
- `NEXT_PUBLIC_WEBSITE_URL=http://NEXT_PUBLIC_WEBAPP_URL_PLACEHOLDER`, so the existing placeholder rewrite (`scripts/replace-placeholder.sh`, run by the Dockerfile and `scripts/start.sh`) points it at the real domain instead of the default `https://cal.com`.

## Data flow at startup

The image's `scripts/start.sh` already does the following on every container start:

1. Replaces the built URL placeholder with `NEXT_PUBLIC_WEBAPP_URL`.
2. Waits for `DATABASE_HOST`.
3. Runs `prisma migrate deploy`.
4. Runs `seed-app-store.ts`, which copies app keys such as `GOOGLE_API_CREDENTIALS` from env into the `App` table.
5. Runs `yarn start`.

Because of step 4, changing a key in the server `.env` and running `deploy.sh` is enough; no manual re-seed is needed.

## Server `.env` contents

Copied from the local `.env`, except:

- `NEXT_PUBLIC_WEBAPP_URL` and `NEXTAUTH_URL` = `https://cal.<domain>`
- `DATABASE_URL` = `postgresql://<user>:<password>@database:5432/<db>` with a new password generated for the server
- `TUNNEL_TOKEN` and `CAL_DOMAIN` added

`NEXTAUTH_SECRET` and `CALENDSO_ENCRYPTION_KEY` are kept unchanged. Credentials in the database are encrypted with `CALENDSO_ENCRYPTION_KEY`, so changing it would break the Google Calendar connection.

## Security

- The image is public and contains no secrets. Secrets exist only in `/opt/cal/.env` (mode 600) and in the gitignored local `deploy/server/.env.server`.
- The only inbound port is SSH. Postgres is not published.
- Scripts never print `.env` values.
- Prisma Studio is not deployed.

## Error handling

- `bootstrap.sh` and `migrate-data.sh` use `set -euo pipefail` and stop at the first failure.
- `migrate-data.sh` refuses to overwrite a non-empty server database.
- `deploy.sh` fails loudly with logs when the health check does not pass, and supports rollback by tag.
- The CI build fails the workflow if the image build or push fails; nothing is deployed automatically.

## Steps only the owner can do

These involve purchases, accounts or credentials:

1. Buy a domain and add it to Cloudflare.
2. Create the VPS (Ubuntu 24.04, amd64, 4 GB) with their SSH key, and share its IP.
3. Cloudflare Zero Trust: create a tunnel with public hostname `cal.<domain>` → `http://calcom:3000`, and paste its token into `deploy/server/.env.server`.
4. GitHub: enable Actions on the fork, then disable every workflow except `Build image` (the upstream ones run on push, pull request or schedule and fail without Cal.com's secrets); after the first build on `main`, set the `cal.diy` GHCR package to public.
5. Google Cloud Console: add `https://cal.<domain>/api/integrations/googlecalendar/callback` as an authorized redirect URI and `https://cal.<domain>` as an authorized JavaScript origin. If the OAuth consent screen is in "Testing", publish it, because Google expires refresh tokens of testing apps after 7 days.
6. Account `reynen` (ADMIN): set a strong password (15+ characters, mixed case, a number) and enable 2FA, otherwise production sign-in downgrades it to an inactive admin (`packages/features/auth/lib/next-auth-options.ts`).

## Verification

1. `build-image.yml` passes and the image appears in GHCR.
2. `bootstrap.sh`, `migrate-data.sh` and `deploy.sh` complete; `deploy.sh` reports healthy; `POST /api/auth/signup` returns 403; only users 42 and 43 exist.
3. `https://cal.<domain>` loads in the browser pane; signing in shows the migrated event types.
4. The owner books a test meeting on their own page with a guest address they control.
5. Invite emails arrive for the invitee, the guest and the organizer, and the Google Calendar event exists.
6. `pull-backup.sh` retrieves a dump after the first 03:00 run (or after running the backup command by hand).

## Risks

- **Build needs a database.** Upstream builds with a live, empty Postgres attached to buildx. Mitigation: the workflow does the same.
- **GHCR packages start private.** If the owner skips making it public, `docker compose pull` fails. `deploy/server/README.md` covers both options: make it public, or `docker login ghcr.io` on the server with a read-only token.
- **Upstream workflows fail in the fork.** They need Cal.com's secrets. Mitigation: owner step 4 disables them.
- **Reminder emails for unconfirmed bookings do not run**, because the cron workflows are disabled. Booking confirmations are sent at booking time, so the goal is unaffected.

## Delivery

Branch `feat/self-host-deploy`, as a draft PR into the fork's `main` (`3376016376joshua-oss/cal.diy`), never upstream. Ten code/config files plus the runbook, all deploy configuration.
