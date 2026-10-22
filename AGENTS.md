# AGENTS.md — Multi-host NixOS flake (homeserver + vps)

Operational notes for an agent working in this repo. Read this before
changing anything; most of it is hard-won and the failure modes are
non-obvious.

## What this repo is

One flake managing two hosts, both running **nixos-unstable**:

| Host | Role | Where |
|---|---|---|
| `homeserver` | Home server. Runs Plex, AdGuard Home. Behind carrier NAT. | `hosts/homeserver/` |
| `vps` | Public gateway at `2.31.95.62` (Hetzner). WireGuard endpoint + Caddy TLS. | `hosts/vps/` |

Traffic path:

```
Internet → https://plex.9485432.xyz:443 (Caddy on vps, Let's Encrypt)
         → wg0 tunnel (10.100.0.1 ↔ 10.100.0.2)
         → http://10.100.0.2:32400 (Plex on homeserver)
```

The point of the tunnel is to **hide the home IP** behind carrier NAT. The
homeserver has no inbound ports; the tunnel is dialled outbound from it.

## Hard rules

- **Do not build locally.** This laptop has a broken Nix install: `/nix/store`
  does not exist, so *any* `nix` command fails with
  `error: opening file "/nix/store": No such file or directory`.
  See "Local Nix is broken" below. Do evaluation and builds on the
  homeserver over SSH.
- **Never commit plaintext secrets.** `secrets/*.yaml` must stay sops
  ciphertext. `.gitignore` covers `*.private`, `*.pub`, `*.key`, `*.pem`,
  `/age-*.txt`, `*.iso`. Verify before every push:
  `git diff --cached | grep -cE '^\+[A-Za-z0-9+/]{43}=$'` must be 0.
- **Never print key material.** When verifying a secret decrypts, compare
  with `cmp` or print a hash — do not `echo` the value. This was violated
  once and a WireGuard private key ended up in a transcript, forcing a
  key rotation. Do not repeat it.
- **Run `git add` before evaluating.** The flake source is a git tree, so
  Nix only sees tracked files. A new untracked `.nix` file gives
  `path '...' does not exist` even though it is on disk.

## Local Nix is broken — full context

`/nix/store` is missing on the laptop. The Arch `nix` package was installed
(and later removed), leaving `nixbld` users and stale systemd units. The
official installer then failed on the existing group and on a zombie
`nix-daemon.service`. This is unresolved.

**Consequence:** always run `nix` commands on the homeserver. A workaround
used mid-session was `nix --store /tmp/nixstore ...`, which works for
evaluation but is not a real fix and produces confusing binary-cache
warnings.

If asked to fix local Nix, the path is: remove leftovers
(`groupdel nixbld`, kill any running `nix-daemon`, `systemctl disable` the
stale units), then run the official installer via Option B in the session
notes. Do not attempt `--store /tmp/...` as a substitute.

## SSH access

```
homeserver     → jack@192.168.0.204 (LAN only; unreachable if off-network)
vps            → root@2.31.95.62    (root login, key-only)
```

Additionally useful:

- The **homeserver can reach the vps as root** (its key is in the vps
  `root` `authorized_keys`). When the laptop cannot reach the vps, drive it
  from the homeserver.
- `nixos-anywhere` runs are best driven **from the homeserver**, not the
  laptop, because the laptop's Nix is broken.

## Standard workflows

### Evaluate / build (on the homeserver)

```bash
rsync -avz --exclude '.git' --exclude '*.iso' . homeserver:~/nixos-config/
ssh homeserver 'cd ~/nixos-config && nix flake check'
```

### Apply to the homeserver

```bash
ssh homeserver 'cd ~/nixos-config && sudo nixos-rebuild switch --flake .#homeserver'
```

### Apply to the vps

The vps pulls the flake from GitHub itself (`system.autoUpgrade`), so a
manual apply is:

```bash
ssh root@2.31.95.62 'nixos-rebuild switch --flake github:jack1916/nixos-config#vps'
```

Note the vps's *live* config lives at `/etc/nixos-config/`, not in the
flake checkout. Files edited there do not persist and are not the source
of truth.

## Patching / auto-update flow

Fully automatic, gated on CI. No human step.

```
CI daily 02:00 UTC (update-flake.yml)
  1. nix flake update
  2. build BOTH hosts          ← the gate
  3. commit flake.lock to main ONLY if both built
main → flake.lock advances
   ↓ machines fetch github:jack1916/nixos-config#<host> nightly at 03:00
homeserver  03:00 +15m jitter → rebuild; reboots only if kernel changed (window 03:00–05:00)
vps         03:00 +10m jitter → rebuild; reboots only if kernel changed (window 03:00–04:30)
```

`allowReboot` does **not** mean a nightly reboot: the module compares
booted vs built kernel/initrd/kernel-modules and reboots only when they
differ.

If you touch the schedule:

- **`rebootWindow` must contain the run time**, or the reboot is skipped
  *silently* and deferred forever.
- **Leave slack for jitter + rebuild.** The windows are wider than the
  delay on purpose.

Do **not** add `--update-input nixpkgs` to either host; that would let a
machine resolve its own nixpkgs and bypass the CI gate.

To test the build+commit path (which otherwise only runs when upstream
moves): Actions → *Update Flake Lock* → Run workflow → tick `force_build`.

Check for pending reboots:

```bash
./scripts/update-check.sh          # both hosts
```

## Things that went wrong here — do not re-introduce them

These are the real failure modes, each of which cost significant time.

1. **`system.autoUpgrade` pointed at a local path.** With a pinned
   `flake.lock` and no `git pull`, the nightly rebuild reproduced the same
   closure forever: **zero security patches**. Both hosts now use
   `github:jack1916/nixos-config#<host>`.

2. **WireGuard MTU 1420 on a carrier-NAT path.** Path MTU caps below 1420,
   so large packets are dropped *silently*. Symptom: TCP connects, HTTP
   headers arrive, body never does — pages hang indefinitely. Small
   responses work, which is deeply misleading. **Measured ceiling:** ICMP
   payloads >1364 bytes dropped → inner IP ≤1392. Both peers are set to
   **1380**. Diagnose with:
   ```bash
   ping -c1 -W2 -M do -s <size> 10.100.0.2
   ```

3. **nixos-anywhere cannot install the vps.** Two reasons:
   - Hetzner x86_64 boots **legacy BIOS**; kexec fails with
     `PEFILE: Unsigned PE binary` and cannot be enabled.
   - There is no `--no-kexec` flag. Skipping the kexec phase
     (`--phases disko,install,reboot`) installs onto the disk that is
     *mounted as `/`*, so the kernel refuses to reload the partition table:
     disko rewrites the GPT and **zeroes the MBR** without creating
     filesystems, leaving an unbootable machine. This happened.
   - **Correct method:** `nixos-infect` converts the provider's Ubuntu image
     in place. See `hosts/vps/README.md` §4 for the full procedure,
     including the manual networking step.

4. **nixos-infect silently skips networking.** It contains the bug
   `[ ! -v $PROVIDER ]` (missing `$`), so provider autodetection never
   runs, `doNetConf` stays unset and `networking.nix` is never generated.
   Result: a host with **no network config** that boots unreachable.
   Fix: run with `PROVIDER=hetznercloud`, or (as was done) write
   `hosts/vps/networking.nix` by hand. Hetzner needs a `/32` address with
   an **onlink** gateway route (`prefixLength = 32`), which DHCP cannot
   express.

5. **nixos-infect `swapon` fails on tmpfs.** It creates a 1 GiB swapfile in
   `/tmp`; if `/tmp` is tmpfs the kernel rejects it with
   `Invalid argument`. Use `NO_SWAP=1` (4 GB RAM is enough without swap).

6. **Re-running nixos-infect does not regenerate networking.** `makeConf`
   begins with `[[ -e /etc/nixos/configuration.nix ]] && return 0`, so once
   the config exists it bails before reaching `makeNetworkingConf`.

7. **sops-nix Go version break.** Master required Go 1.26 while nixpkgs
   25.11 shipped 1.25.10, breaking `sops-install-secrets`. It was worked
   around by pinning sops-nix *and* overriding `vendorHash` via
   `sops.package`/`validationPackage` — an overlay does **not** work,
   because the module `callPackage`s sops-nix directly. **This is now
   obsolete:** the flake moved to nixos-unstable, which has Go 1.26, so
   the pin and the hash override are both removed. Do not restore them.

8. **`virtualHosts.${domain}`-style assumptions and Caddy details.**
   `services.caddy.enableReload` defaults true and needs the admin API, so
   do not set `admin off`. `grace_period 30s` is set to stop reloads
   hanging on long media streams.

## Secrets

Encrypted with sops + age, committed as ciphertext.

| File | YAML key | Used by |
|---|---|---|
| `secrets/vps.yaml` | `wireguard_private_key` | `hosts/vps/wireguard.nix` |
| `secrets/homeserver.yaml` | `wireguard_private_key` | `hosts/homeserver/wireguard-client.nix` |

- Age recipients are in `.sops.yaml`. Each file is encrypted to **its host
  plus an admin key**, so the homeserver cannot read the vps secret and
  vice versa.
- Runtime path: `/run/secrets/wireguard/{vps,homeserver}-private-key`.
  sops-nix needs `/var/lib/sops-nix/key.txt` on each host to decrypt.
- Editing: `SOPS_AGE_KEY_FILE=~/age-keys/admin.txt sops secrets/vps.yaml`.
  The admin private key lives **outside** the repo (`~/age-keys/`).
- **No PSKs.** WireGuard uses public-key auth only. If you ever add a PSK
  it must go on *both* peers together, or the handshake fails silently.

## WireGuard

| | vps | homeserver |
|---|---|---|
| Tunnel IP | `10.100.0.1/24` | `10.100.0.2/24` |
| Endpoint | static, `51820/udp` | `2.31.95.62:51820` |
| MTU | 1380 | 1380 |
| Keepalive | n/a | `persistentKeepalive = 25` |

The keepalive is what holds the carrier-NAT mapping open. The vps has no
endpoint for the homeserver peer (it dials in).

Firewall on the vps: **tcp 22/80/443, udp 51820**, everything else
dropped. `wg0` is a trusted interface. No NAT or forwarding — Caddy proxies
in userspace.

Note the WireGuard module does **not** open its listen port automatically;
`allowedUDPPorts = [ 51820 ]` is required the vps.

## DNS

- `plex.9485432.xyz` → `2.31.95.62`, **grey-clouded (DNS only)**.
- It must **not** be Cloudflare-proxied (orange cloud): ACME HTTP-01
  validation would fail, and Cloudflare's 100 MB body cap breaks Plex
  streaming and seeking.
- Verify: `dig +short plex.9485432.xyz` returns exactly `2.31.95.62`.
  If it returns `104.21.x`/`172.67.x`, it is being proxied.

## Repo layout

| Path | Notes |
|---|---|
| `flake.nix` | Two hosts via `mkSystem`; nixpkgs = nixos-unstable |
| `hosts/homeserver/` | `default.nix` + `wireguard-client.nix` |
| `hosts/vps/` | `default.nix`, `wireguard.nix`, `caddy.nix`, `hardware-configuration.nix`, `networking.nix`, `README.md` |
| `modules/services/plex.nix` | Plex, GPU transcoding, read-only media ACLs |
| `hosts/vps/README.md` | **The detailed vps runbook.** Read it before touching the vps. |
| `scripts/update-check.sh` | current vs booted generation, next timer, reboot pending |
| `dev-mode.sh` | local helper (evaluation-only) |

`hosts/vps/hardware-configuration.nix` holds **UUIDs from the current
Hetzner image**. Rebuilding the vps changes them; update the file or the
machine will not mount root.

## Verification before committing

```bash
rsync -avz --exclude '.git' --exclude '*.iso' . homeserver:~/nixos-config/
ssh homeserver 'cd ~/nixos-config && nix flake check'
git diff --cached | grep -cE '^\+[A-Za-z0-9+/]{43}=$'    # must print 0
```

Confirm intent by evaluating, not by reading:

```bash
ssh homeserver 'cd ~/nixos-config && nix eval --json \
  .#nixosConfigurations.vps.config.system.autoUpgrade'
```

## Style

- Comments should explain **why**, especially where a value looks wrong
  (MTU 1380, no PSK, wide reboot windows). Several comments in this repo
  exist specifically to stop a future agent "fixing" a deliberate choice.
- Prefer declarative over imperative. If something is only configured on a
  live host and not in git, treat that as a bug — that is how
  `hosts/vps/networking.nix` was nearly lost.
