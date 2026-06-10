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
#   ./client/finder-mount.sh --install-agent     # auto-(re)mount on login + every 60s
#   ./client/finder-mount.sh --uninstall-agent   # stop auto-mounting
#   HOST=contabo REMOTE=/root MOUNT="$HOME/mnt/contabo" ./client/finder-mount.sh
#
# Migrating to a new instance? Nothing here changes — the mount follows the
# `contabo` SSH alias. To avoid even editing that alias's IP after a migration,
# name the Tailscale node `contabo` and point the alias HostName at its MagicDNS
# name (`contabo`) instead of a hardcoded IP; then a new box is zero-touch.
set -euo pipefail

HOST="${HOST:-contabo}"          # SSH alias from ~/.ssh/config (key auth, Tailscale)
REMOTE="${REMOTE:-/}"            # path on the box to expose (whole filesystem).
                                 # Safe to mount /: the home dir is a sub-folder, not
                                 # the mount root. But do NOT change perms on /root
                                 # itself via Finder — sshd StrictModes would then lock
                                 # out key logins.
MOUNT="${MOUNT:-$HOME/mnt/$HOST}"
LABEL="dev.attolabs.finder-mount.${HOST}"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

# Reveal in Finder only when run interactively (a tty); silent from the agent.
reveal() { [ -t 1 ] && open "$MOUNT" >/dev/null 2>&1 || true; }

# --- unmount mode ---------------------------------------------------------
if [ "${1:-}" = "-u" ] || [ "${1:-}" = "--unmount" ]; then
  umount "$MOUNT" 2>/dev/null || diskutil unmount force "$MOUNT" 2>/dev/null || true
  echo "unmounted: $MOUNT"
  exit 0
fi

# --- LaunchAgent: auto-(re)mount on login and every 60s -------------------
if [ "${1:-}" = "--install-agent" ]; then
  SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  LOG="$HOME/Library/Logs/finder-mount-${HOST}.log"
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>${SELF}</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOST</key><string>${HOST}</string>
    <key>REMOTE</key><string>${REMOTE}</string>
    <key>MOUNT</key><string>${MOUNT}</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>60</integer>
  <key>StandardOutPath</key><string>${LOG}</string>
  <key>StandardErrorPath</key><string>${LOG}</string>
</dict>
</plist>
PLISTEOF
  launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "installed LaunchAgent: ${LABEL}"
  echo "  it (re)mounts on login and every 60s — stale mounts self-heal automatically"
  echo "  log:   $LOG"
  echo "  stop:  $0 --uninstall-agent"
  exit 0
fi

if [ "${1:-}" = "--uninstall-agent" ]; then
  launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
  rm -f "$PLIST"
  echo "removed LaunchAgent: ${LABEL} (current mount left as-is)"
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

# Serialize runs. The LaunchAgent fires every 60s; if a previous run is still
# mounting/probing, overlapping runs can race and tear down a HEALTHY mount
# (the flapping that caused "remote host has disconnected"). An atomic mkdir
# lock makes a new run bow out instead.
LOCK="${TMPDIR:-/tmp}/finder-mount-${HOST}.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  # A normal run finishes in seconds; if the lock is older than 3 min it was
  # orphaned by a killed run — steal it so we never block remounts forever.
  age=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || echo 0) ))
  if [ "$age" -gt 180 ]; then
    rmdir "$LOCK" 2>/dev/null || true
    mkdir "$LOCK" 2>/dev/null || { echo "lock contended — skipping"; exit 0; }
  else
    echo "another run in progress — skipping"; exit 0
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

# Liveness check that CANNOT false-positive. The old approach probed the mount
# with `ls`+timeout, but in the LaunchAgent's context that probe intermittently
# reported a healthy mount as stale — so the agent tore it down and remounted
# every 60s, kicking Finder out of the volume. Instead: the mount is backed by a
# persistent `sshfs` process whose argv contains the mountpoint. If that process
# is alive, the mount is live — do NOTHING (sshfs's own `-o reconnect` rides out
# transient network drops). Only if the mount is listed but its sshfs is gone is
# it genuinely dead, so we clear and remount.
if mount | grep -q " on ${MOUNT} "; then
  if pgrep -f "sshfs.*${MOUNT}" >/dev/null 2>&1; then
    echo "healthy (mounted, sshfs alive) — nothing to do"; reveal; exit 0
  fi
  echo "==> mount present but sshfs process gone — clearing"
  umount "$MOUNT" 2>/dev/null || diskutil unmount force "$MOUNT" >/dev/null 2>&1 || true
fi

echo "==> Mounting ${HOST}:${REMOTE} -> ${MOUNT}"
# reconnect: survive brief network drops; ServerAlive*: detect dead links fast;
# volname: Finder sidebar label; follow_symlinks: traverse the box's symlinks.
sshfs "${HOST}:${REMOTE}" "$MOUNT" \
  -o reconnect,follow_symlinks,defer_permissions,volname="$HOST",ServerAliveInterval=15,ServerAliveCountMax=3,ConnectTimeout=10

reveal
echo "Mounted. Finder > Locations shows it as '${HOST}'. Unmount: $0 -u"
