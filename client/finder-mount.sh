#!/usr/bin/env bash
# Mount the dev box into macOS Finder over SSH/Tailscale, using FUSE-T (no kernel
# extension) + sshfs. CLIENT-SIDE ONLY — this is NOT part of the Ansible playbook,
# which runs ON the box. Keep it here so the Mac setup is version-controlled too.
#
# First run installs FUSE-T (one macOS password prompt) + sshfs; every run after
# that just mounts, with NO password (SSH key auth via your ~/.ssh/config alias).
#
#   ./client/finder-mount.sh            # install deps if missing, then mount
#   ./client/finder-mount.sh -u         # unmount
#   HOST=contabo REMOTE=/root MOUNT="$HOME/mnt/contabo" ./client/finder-mount.sh
#
# Migrating to a new instance? Nothing here changes — the mount follows the
# `contabo` SSH alias. To avoid even editing that alias's IP after a migration,
# name the Tailscale node `contabo` and point the alias HostName at its MagicDNS
# name (`contabo`) instead of a hardcoded IP; then a new box is zero-touch.
set -euo pipefail

HOST="${HOST:-contabo}"          # SSH alias from ~/.ssh/config (key auth, Tailscale)
REMOTE="${REMOTE:-/root}"        # path on the box to expose
MOUNT="${MOUNT:-$HOME/mnt/$HOST}"

# --- unmount mode ---------------------------------------------------------
if [ "${1:-}" = "-u" ] || [ "${1:-}" = "--unmount" ]; then
  umount "$MOUNT" 2>/dev/null || diskutil unmount force "$MOUNT" 2>/dev/null || true
  echo "unmounted: $MOUNT"
  exit 0
fi

# --- deps (one-time) ------------------------------------------------------
command -v brew >/dev/null || { echo "Homebrew required: https://brew.sh"; exit 1; }
if ! command -v sshfs >/dev/null 2>&1 && [ ! -x /usr/local/bin/sshfs ]; then
  echo "==> Installing FUSE-T + sshfs (one-time; FUSE-T will ask for your macOS password)"
  brew tap macos-fuse-t/homebrew-cask >/dev/null 2>&1 || true
  brew install fuse-t fuse-t-sshfs
fi

# --- mount ----------------------------------------------------------------
mkdir -p "$MOUNT"

# A FUSE/sshfs mount goes stale after sleep or a network drop: it still appears
# in the mount table, but Finder shows "you don't have permission to see its
# contents" and any access hangs. Probe it with a short timeout (perl alarm —
# always present on macOS, no GNU coreutils needed); if it's healthy, done; if
# it's stale, force-clear it so a re-run always recovers.
if mount | grep -q " on ${MOUNT} "; then
  if perl -e 'alarm 6; exec @ARGV or exit 1' ls "$MOUNT" >/dev/null 2>&1; then
    echo "already mounted (healthy): $MOUNT"; open "$MOUNT"; exit 0
  fi
  echo "==> stale mount detected — clearing"
  umount "$MOUNT" 2>/dev/null || diskutil unmount force "$MOUNT" >/dev/null 2>&1 || true
fi

echo "==> Mounting ${HOST}:${REMOTE} -> ${MOUNT}"
# reconnect: survive brief network drops; ServerAlive*: detect dead links fast;
# volname: Finder sidebar label; follow_symlinks: traverse the box's symlinks.
sshfs "${HOST}:${REMOTE}" "$MOUNT" \
  -o reconnect,follow_symlinks,defer_permissions,volname="$HOST",ServerAliveInterval=15,ServerAliveCountMax=3

open "$MOUNT"
echo "Mounted. Finder > Locations shows it as '${HOST}'. Unmount: $0 -u"
