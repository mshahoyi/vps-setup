# Security model

## The honest limit: you can't hide a secret from root on the same box

If an attacker gets **root on this machine**, any credential the machine can *use*
is theirs too. Root can read files, dump process memory (`/proc/<pid>/mem`,
`/proc/<pid>/environ`), and `ptrace` running processes. Encryption-at-rest doesn't
help, because the decryption key has to be reachable by whatever process uses the
secret — so root reaches it as well. Only hardware-backed keys (TPM / Secure
Enclave / YubiKey) keep a secret off the host, and a Contabo VPS doesn't give you a
trustworthy one.

So the goal is **not** "make the PAT unusable even with root." It's two things:

1. **Minimize blast radius** — if the credential leaks, make it nearly worthless.
2. **Prevent root compromise in the first place** — see *Hardening* below.

## Unattended git access: use a least-privilege, expiring fine-grained PAT

This box runs git unattended (cron, scripts while you're disconnected), so SSH
agent-forwarding (key stays on your laptop) isn't an option — something has to live
on the box. Make that something as low-value as possible:

Create a **fine-grained PAT** at https://github.com/settings/tokens (Fine-grained):
- **Resource owner:** `z3research` (so it can reach those repos)
- **Repository access:** *Only select repositories* → `colm2026`, `auditing-agents`
- **Permissions:** `Contents: Read-only` (or `Read and write` only if automation must push)
- **Expiration:** short — 30 days. Rotate on a calendar reminder.

A token that is "these 2 repos, read-only, expires in 30 days" is almost useless to
an attacker, and a rotation makes any leak self-healing.

Install it onto the box without committing it anywhere — pass it at runtime:

```bash
GITHUB_PAT=github_pat_xxx ansible-playbook -i inventory.ini site.yml --tags hardening
```

The playbook writes it to `~/.git-credentials` with mode `0600` and enables git's
`store` credential helper. The PAT is never printed (`no_log`) and never enters git.

### Alternative: per-repo read-only deploy keys
Even tighter blast radius — an SSH key added to a *single* repo, read-only. Generate
on the box (`ssh-keygen -t ed25519 -f ~/.ssh/colm2026`), add the public key under that
repo's *Settings > Deploy keys*, and clone via SSH. A leak then exposes exactly one
repo, read-only. More setup per repo; pick this if you want the strongest scoping.

## Hardening (what actually protects you)

`tasks/hardening.yml` (run by default, or `--tags hardening`) applies:

- **Key-only SSH** — password auth + root password login disabled. Login keys are
  pulled from `https://github.com/<github_keys_user>.keys`. *Safety:* if no keys are
  found there, password auth is left ON and the run warns instead of locking you out.
- **Firewall (ufw)** — default-deny incoming, only the SSH port open. SSH is allowed
  *before* the firewall is enabled so your session isn't dropped.
- **fail2ban** — bans IPs that brute-force SSH.
- **Automatic security updates** — `unattended-upgrades` patches the kernel/openssl
  holes that lead to root.
- **Optional non-root sudo user** — set `create_admin_user: true` for privilege
  separation (off by default while automation runs as root).

### Tailscale: take SSH off the public internet (recommended)

Key-only SSH still leaves port 22 exposed to scanners. Tailscale puts SSH on a
private WireGuard mesh so the port can be removed from the public internet
entirely — the single biggest remaining attack-surface reduction.

Flow (order matters — never lock yourself out):
1. `ansible-playbook -i inventory.ini site.yml --tags tailscale` — installs
   Tailscale and allows the `tailscale0` interface through ufw.
2. `tailscale up` on the box — prints a URL; approve it in your browser (sign in
   with GitHub/Google to create/join your tailnet). Or pass
   `TAILSCALE_AUTHKEY=tskey-...` at runtime for non-interactive bring-up.
3. **Verify** you can `ssh root@<tailscale-ip>` over the tailnet.
4. Only then set `tailscale_lock_ssh: true` and re-run `--tags tailscale` to
   remove public port 22.

Recovery if anything goes wrong: Contabo's web console reaches the VM regardless
of the firewall. Also set a device-key expiry / ACLs in the Tailscale admin
console rather than "allow all."

### Before you enable key-only login
Make sure you have an SSH key on your GitHub account that you hold the private key
for locally, or you'll lock yourself out:

```bash
ssh-keygen -t ed25519                 # on your laptop, if you don't have one
gh ssh-key add ~/.ssh/id_ed25519.pub  # registers it at github.com/<you>.keys
```

Then the playbook installs it into the box's `authorized_keys` automatically.
