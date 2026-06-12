#!/usr/bin/env bash
#
# Paste-once bootstrap for a fresh VPS.
#
#   - installs git + GitHub CLI + Ansible (the minimum needed to self-provision)
#   - authenticates with GitHub via the device/web flow (one interaction, no secrets typed)
#   - clones this setup repo and hands off to Ansible (site.yml) for everything else
#
# Usage on a fresh box (as root or a sudo user):
#
#   # If this repo is PUBLIC:
#   curl -fsSL https://raw.githubusercontent.com/SETUP_REPO/main/bootstrap.sh | bash
#
#   # If this repo is PRIVATE (or you just prefer): paste this whole file into the shell,
#   # or scp it over, then: bash bootstrap.sh
#
# Override the setup repo location if you forked/renamed it:
#   SETUP_REPO=youruser/vps-setup bash bootstrap.sh
#
set -euo pipefail

SETUP_REPO="${SETUP_REPO:-mshahoyi/vps-setup}"
SETUP_DIR="${SETUP_DIR:-$HOME/vps-setup}"

# sudo only if we are not already root
SUDO=""
if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi

echo "==> Installing base tooling (git, curl, wget)"
$SUDO apt-get update -y
$SUDO apt-get install -y git curl wget ca-certificates gnupg

echo "==> Installing GitHub CLI (gh)"
if ! command -v gh >/dev/null 2>&1; then
  $SUDO mkdir -p -m 755 /etc/apt/keyrings
  wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | $SUDO tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  $SUDO chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | $SUDO tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  $SUDO apt-get update -y
  $SUDO apt-get install -y gh
fi

echo "==> Installing Ansible"
if ! command -v ansible-playbook >/dev/null 2>&1; then
  $SUDO apt-get install -y ansible
fi

echo "==> Authenticating with GitHub"
if ! gh auth status >/dev/null 2>&1; then
  # --web prints a one-time code + URL; open it on your laptop and paste the code.
  # `--scopes workflow` is needed to push .github/workflows/* (CI) — GitHub gates
  # workflow files behind that scope; the default `repo` scope alone is rejected.
  gh auth login --hostname github.com --git-protocol https --web --scopes workflow
fi
# Make git use gh's token as its credential helper -> private clones just work.
gh auth setup-git

echo "==> Fetching setup repo ($SETUP_REPO)"
if [ ! -d "$SETUP_DIR/.git" ]; then
  git clone "https://github.com/$SETUP_REPO.git" "$SETUP_DIR"
else
  git -C "$SETUP_DIR" pull --ff-only
fi

echo "==> Running Ansible playbook"
cd "$SETUP_DIR"
ansible-playbook -i inventory.ini site.yml

echo
echo "==> Done. Remaining manual step: run 'claude' once and log in."
