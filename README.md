# vps-setup

Version-controlled, (mostly) hands-off provisioning for a fresh VPS, using Ansible.

It installs base CLI tools, tmux (with config), Node + **Claude Code**, sets your
git identity, and clones your working repos. Ansible tasks are idempotent — re-running
is safe and only applies what's missing.

## How it works

The playbook runs **on the box itself** (Ansible with a `localhost` local connection),
so the whole flow is a single paste on a fresh server. `bootstrap.sh` installs the
minimum (git, gh, ansible), authenticates with GitHub, clones this repo, and runs
`site.yml`.

## Usage on a fresh VPS

SSH in, then:

```bash
# If this repo is PUBLIC:
curl -fsSL https://raw.githubusercontent.com/mshahoyi/vps-setup/main/bootstrap.sh | bash

# If this repo is PRIVATE: paste the contents of bootstrap.sh into the shell, then:
bash bootstrap.sh
```

You'll be prompted exactly twice:

1. **GitHub login** — `gh` prints a one-time code + URL; open it on your laptop, paste
   the code. (No password/token typed on the server.) After this, private clones work.
2. **Claude Code login** — run `claude` once and sign in. (No clean non-interactive
   browser login exists; an `ANTHROPIC_API_KEY` env var is the only alternative.)

Everything else — apt packages, tmux, Node, Claude Code install, repo clones — is
non-interactive.

## Security

The box is hardened by default (key-only SSH, firewall, fail2ban, auto-updates).
**Read [SECURITY.md](SECURITY.md) before relying on it** — especially the note that a
secret on the box is only as safe as the box (root compromise = secret compromise),
and the recipe for a least-privilege, expiring PAT for unattended git access.

Before key-only SSH locks in, make sure you have an SSH key registered on GitHub that
you hold locally (`ssh-keygen` + `gh ssh-key add`). If none is found at
`github.com/<you>.keys`, the playbook leaves password login on and warns rather than
locking you out.

## Customizing

Edit `group_vars/all.yml`:

- `github_repos` — repos to clone (`owner/name`), into `~/dev/`
- `apt_packages` — base packages
- `node_major` — Node version
- `git_user_name` / `git_user_email` — global git identity

## Run a subset

Tasks are tagged, so you can apply just part of it:

```bash
ansible-playbook -i inventory.ini site.yml --tags repos     # just (re)clone repos
ansible-playbook -i inventory.ini site.yml --tags base,node
```

## Driving a remote box from your laptop instead

The local-run model above is simplest. If you'd rather manage one (or many) servers
from your laptop the classic way, edit `inventory.ini` (a `[vps]` group is stubbed in)
and run `ansible-playbook site.yml` from your laptop — no need to install Ansible on
the server. Requires SSH access (a key in `~/.ssh/authorized_keys` on the box).

## Client (macOS): mount the box in Finder

`client/finder-mount.sh` mounts the box's filesystem into Finder over your
existing SSH/Tailscale connection, using FUSE-T (no kernel extension) + sshfs.
This is **client-side**, not part of the playbook (which runs on the box).

```bash
./client/finder-mount.sh        # first run installs FUSE-T (one password), then mounts
./client/finder-mount.sh -u     # unmount
```

It targets the `contabo` SSH alias, so a migration needs nothing here. To make a
migration fully zero-touch, name the new Tailscale node `contabo` and set the
alias `HostName` to its MagicDNS name (`contabo`) instead of a hardcoded IP.
