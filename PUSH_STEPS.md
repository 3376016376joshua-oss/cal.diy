# Push Steps Log

Compact summary of code pushes to the remote repository.
Each entry is a short snapshot of one push — enough context to recall what happened, not a full transcript.

## Standard push procedure
1. Stage changes  → `git add`
2. Commit         → `git commit -m "..."`
3. Set upstream   → `git push -u origin <branch>` (first push of a branch only)
4. Push           → `git push`

## Push history

### 2026-10-31 — feat/self-host-1-ci … feat/self-host-5-deploy (self-host deploy kit, 5 stacked branches)
- Commits:
  - `ci: build, smoke-test and publish the Cal.diy image to GHCR` (`37ef1c2`)
  - `feat(deploy): add the server env generator and compose stack` (`68db056`)
  - `feat(deploy): add server bootstrap and the fake-server test harness` (`f571875`)
  - `feat(deploy): add the one-time data import with seed-account removal` (`afb24bf`)
  - `feat(deploy): add guarded deploy, backup pull and the runbook` (`f29031c`)
- Files: `.github/workflows/build-image.yml`, `deploy/server/*` (scripts, compose file, tests, README), `.gitignore`, plus the spec and plan in `docs/superpowers/`
- Steps:
  - Stage and commit: skipped (already committed).
  - Upstream and push: one `git push -u origin <5 branches>` to the fork `3376016376joshua-oss/cal.diy`.
- Notes:
  - All five are new branches. Draft PRs [#1](https://github.com/3376016376joshua-oss/cal.diy/pull/1) and [#2](https://github.com/3376016376joshua-oss/cal.diy/pull/2) target `main`; #3→#2, #4→#3 and #5→#4 are stacked, so retarget each to `main` once the PR below it merges.
  - Upstream workflows were disabled on the fork first.
  - Only #1 runs CI (Build image).
  - Local edits to `apps/web/next.config.ts` and `.claude/launch.json` were not pushed.

### 2026-11-17 - fix/dev-allowed-origins
- Commits:
  - `fix(web): allow the configured app host as a dev origin` (`ca9e78ccfb`)
  - `chore: add preview launch configurations for the web app` (`70af90682f`)
  - `docs: add the push log` (this file)
- Files: `apps/web/next.config.ts`, `.claude/launch.json`, `PUSH_STEPS.md`
- Steps: stage, commit, `git push -u origin fix/dev-allowed-origins` (new branch, cut from `origin/main`).
- Notes:
  - Pull request to `main` on the fork `3376016376joshua-oss/cal.diy`.
  - `yarn type-check:ci --force` cannot run on this Mac's Node 26 (the Prisma zod generator fails); the web app was checked with `yarn workspace @calcom/web type-check` instead.
