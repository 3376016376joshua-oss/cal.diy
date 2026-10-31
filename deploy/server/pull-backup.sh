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

# A backup holds the whole database, so only the current user may read it.
umask 077
mkdir -p "$dest"
scp "$target:$latest" "$dest/"
echo "Saved $dest/$(basename "$latest")"
