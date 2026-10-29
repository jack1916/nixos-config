# AGENTS.md — NixOS flake (homeserver)

Operational notes for an agent working in this repo. Read this before
changing anything; most of it is hard-won and the failure modes are
non-obvious.

## What this repo is

One flake managing **one host**, running **nixos-unstable**:

| Host | Role | Where |
|---|---|---|
| `homeserver` | Home server. Runs Plex and AdGuard Home. Behind carrier NAT. | `hosts/homeserver/` |

There used to be a second host, a public VPS that acted as a WireGuard
endpoint plus Caddy TLS reverse proxy so Plex could be reached from the
internet. **It has been removed entirely** (see "The VPS is gone" below),
along with the tunnel, the sops/WireGuard secrets, and every documented
install method. Do not reintroduce any of it without being asked.

## Hard rules

- **Do not build locally.** This laptop has a broken Nix install: `/nix/store`
  does not exist, so *any* `nix` command fails with
  `error: opening file "/nix/store": No such file or directory`.
  See "Local Nix is broken" below. Do evaluation and builds on the
  homeserver over SSH.
- **Never commit plaintext secrets.** There are currently **no secrets in
  this repo** (the WireGuard keys were removed with the VPS). If you add
  any, they go through sops as ciphertext; `.gitignore` already covers
  `*.private`, `*.pub`, `*.key`, `*.pem`, `/age-*.txt`, `*.iso`. Verify
  before every push:
  `git diff --cached | grep -cE '^\+[A-Za-z0-9+/]{43}=$'` must be 0.
- **Never print key material.** When verifying a secret decrypts, compare
  with `cmp` or print a hash — do not `echo` the value. This was violated
  once and a WireGuard private key ended up in a transcript, forcing a
  key rotation. Do not repeat it.
- **The homeserver build target is not a git tree.** `~/nixos-config` (aka
  `/etc/nixos`, a symlink to the same dir) is a plain rsync target on
  purpose, so there is no `git add` step and no "untracked file" trap when
  building there. Just make sure your `rsync` used `--delete` and included
  every new file. See "Where the source of truth is" below.

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
```

That is the only host. (There used to be a `vps → root@2.31.95.62` entry;
the VM has been deleted and `2.31.95.62` no longer belongs to this
project. Do not try to SSH to it.)

## Where the source of truth is — READ THIS FIRST

**The source of truth is GitHub** (`jack1916/nixos-config`). Your laptop
checkout is where you edit and commit. The homeserver has NO working copy
that matters.

There is exactly ONE directory on the homeserver:

```
/etc/nixos  ->  /home/jack/nixos-config      (a symlink; the SAME dir)
```

It is a **plain, non-git rsync target** used only to run `nix flake check`
and `nix build`. It is deliberately **not a git repository**: an earlier
setup made it a clone, which meant Nix imported it as a git tree and the
build depended on what happened to be staged at that moment. That caused
agents to build different trees and get confusing `Git tree is dirty`
results. Do not `git init`, `git clone`, or `git commit` in there.

Corollaries:

- Never `git pull` / `git push` on the homeserver. Push from the laptop.
- Never `git add` on the homeserver to "fix" a build. Just rsync again.
- `system.autoUpgrade` builds `github:jack1916/nixos-config#homeserver`,
  not this directory. So the directory is a **scratch validation area**;
  the running system is always from GitHub.

## Standard workflows

### Validate a change (the ONLY normal workflow)

The helper does the sync + check/build for you:

```bash
./dev-mode.sh check     # rsync --delete, then nix flake check
./dev-mode.sh build     # rsync --delete, then build the toplevel
```

Or, by hand — rsync with `--delete` so the target mirrors your working
tree exactly (including deletions), then build:

```bash
rsync -avz --delete --exclude '.git' --exclude '*.iso' --exclude '*.iso.sha256' \
  . homeserver:~/nixos-config/
ssh homeserver 'cd ~/nixos-config && nix flake check'
ssh homeserver 'cd ~/nixos-config && nix build --no-link \
  .#nixosConfigurations.homeserver.config.system.build.toplevel'
```

`--delete` is important: without it, files you deleted locally linger on the
homeserver and get evaluated (this is how a deleted `hosts/vps/` kept
appearing in builds).

Build from `.` (the directory), **not** from a `git+file://` or a flake ref.
A plain path evaluates the files exactly as they are, with no dirty-tree
ambiguity.

### Apply (the homeserver installs it itself — you rarely need this)

The homeserver applies changes automatically at 03:00 from GitHub. That is
the normal path, and it only runs **committed and pushed** code.

To apply **now** (e.g. to test a rebuild without waiting), build from a
path you just rsynced:

```bash
ssh homeserver 'cd ~/nixos-config && sudo nixos-rebuild switch --flake .#homeserver'
```

This is the only case where the scratch directory is authoritative, and it
is still just a one-shot switch — it does not change what autoUpgrade
tracks. If you want the change to persist, commit and push.

### Do not do this

- Do not maintain a second checkout, and do not build from a remote flake
  ref on the homeserver while editing locally. Pick ONE tree per build.
- Do not commit from the homeserver. Its directory is not a repo any more,
  so this is impossible by design.

## Patching / auto-update flow

Fully automatic, gated on CI. No human step.

```
CI daily 02:00 UTC (update-flake.yml)
  1. nix flake update
  2. build the homeserver      ← the gate
  3. commit flake.lock to main ONLY if it built
main → flake.lock advances
   ↓ machine fetches github:jack1916/nixos-config#homeserver nightly at 03:00
homeserver  03:00 +15m jitter → rebuild; reboots only if kernel changed (window 03:00–05:00)
```

`allowReboot` does **not** mean a nightly reboot: the module compares
booted vs built kernel/initrd/kernel-modules and reboots only when they
differ.

If you touch the schedule:

- **`rebootWindow` must contain the run time**, or the reboot is skipped
  *silently* and deferred forever.
- **Leave slack for jitter + rebuild.** The window is wider than the
  delay on purpose.

  Do **not** add `--update-input nixpkgs` to the host; that would let the
  machine resolve its own nixpkgs and bypass the CI gate.

To test the build+commit path (which otherwise only runs when upstream
moves): Actions → *Update Flake Lock* → Run workflow → tick `force_build`.

Check for pending reboots:

```bash
./scripts/update-check.sh
```

## Things that went wrong here — do not re-introduce them

These are the real failure modes, each of which cost significant time.
Most are about the removed VPS; they are kept because they are the reason
it was removed, and so nobody repeats the attempt.

1. **`system.autoUpgrade` pointed at a local path.** With a pinned
   `flake.lock` and no `git pull`, the nightly rebuild reproduced the same
   closure forever: **zero security patches**. The homeserver now uses
   `github:jack1916/nixos-config#homeserver`.

2. **WireGuard MTU 1420 on a carrier-NAT path.** Path MTU caps below 1420,
   so large packets are dropped *silently*. Symptom: TCP connects, HTTP
   headers arrive, body never does — pages hang indefinitely. Small
   responses work, which is deeply misleading. **Measured ceiling:** ICMP
   payloads >1364 bytes dropped → inner IP ≤1392. Both peers were set to
   **1380**. This is moot now (no tunnel), but if a tunnel is ever rebuilt,
   diagnose with:
   ```bash
   ping -c1 -W2 -M do -s <size> 10.100.0.2
   ```

3. **nixos-anywhere cannot install a Hetzner x86_64 VM.** Two reasons:
   - Hetzner x86_64 boots **legacy BIOS**; kexec fails with
     `PEFILE: Unsigned PE binary` and cannot be enabled.
   - There is no `--no-kexec` flag. Skipping the kexec phase
     (`--phases disko,install,reboot`) installs onto the disk that is
     *mounted as `/`*, so the kernel refuses to reload the partition table:
     disko rewrites the GPT and **zeroes the MBR** without creating
     filesystems, leaving an unbootable machine. This happened.
   - Still an open upstream problem: nixos-anywhere #651
     (`kexec_file_load failed` on Hetzner CX23).

4. **nixos-infect silently skips networking.** It contains the bug
   `[ ! -v $PROVIDER ]` (missing `$`), so provider autodetection never
   runs, `doNetConf` stays unset and `networking.nix` is never generated.
   Result: a host with **no network config** that boots unreachable.
   Hetzner Cloud needs a `/32` address with an **onlink** gateway route
   (`prefixLength = 32`), which DHCP cannot express.

5. **nixos-infect `swapon` fails on tmpfs.** It creates a 1 GiB swapfile in
   `/tmp`; if `/tmp` is tmpfs the kernel rejects it with
   `Invalid argument`. Use `NO_SWAP=1` (4 GB RAM is enough without swap).

6. **nixos-infect + systemd stage-1 = a silently dead host, and the
   workaround is gone.** nixpkgs PR #435781 (merged 2026-04-08) made
   `boot.initrd.systemd.enable = true` the default. The systemd stage-1
   initrd **cannot lustrate**, so a nixos-infect conversion never sweeps
   the old distro into `/old-root`: the NixOS kernel boots against the old
   distro's `/etc`, systemd loads the old distro's units, and the machine
   comes up **with no networking and appears dead while the console still
   works**. The script exits 0, so it looks successful. Upstream issue
   #276; fixes #267/#269 **unmerged**.

   The old workaround was `boot.initrd.systemd.enable = false`. That
   option **no longer exists**: the scripted initrd has been removed from
   nixpkgs, so setting it is a **hard assertion failure**
   (`Scripted initrd has been removed`), which is what broke the
   `Update Flake Lock` CI gate.

   **There is now no workaround, so nixos-infect cannot produce a bootable
   host at all.** Do not attempt a nixos-infect install, and do not
   re-add `boot.initrd.systemd.enable` (it does not exist). The only
   supported install for a Hetzner VM is from a custom NixOS ISO so the
   machine is NixOS from first boot.

   The other half of this failure, which still applies to any hand-written
   networking: `defaultGateway` must use the attrs form
   `{ address; interface; }`. The bare-string form nixos-infect generated
   stopped producing a usable default route in 26.05+ (upstream #271),
   which is a second independent way to boot with no networking.

7. **A MAC-based udev rename rule caused a total network outage.** nixos-infect
   generated `ATTR{address}="<mac>", NAME="eth0"` plus a `/32` onlink route.
   On one rebuild the udev rule re-fired, the interface did not end up named
   `eth0`, `network-addresses-eth0.service` never applied the address, and
   the host became unreachable while the console still worked. Do not
   reintroduce MAC-based rename rules.

8. **Re-running nixos-infect does not regenerate networking.** `makeConf`
   begins with `[[ -e /etc/nixos/configuration.nix ]] && return 0`, so once
   the config exists it bails before reaching `makeNetworkingConf`.

9. **sops-nix Go version break.** Master required Go 1.26 while nixpkgs
   25.11 shipped 1.25.10, breaking `sops-install-secrets`. It was worked
   around by pinning sops-nix *and* overriding `vendorHash` — an overlay
   does **not** work, because the module `callPackage`s sops-nix directly.
   **This is obsolete twice over:** the flake moved to nixos-unstable
   (which has Go 1.26), and sops-nix itself has been removed along with the
   VPS secrets. Do not restore either.

10. **Caddy details (only relevant if TLS is ever reintroduced).**
    `services.caddy.enableReload` defaults true and needs the admin API, so
    do not set `admin off`. `grace_period 30s` was set to stop reloads
    hanging on long media streams.

## The VPS is gone — what that means

The VPS (`2.31.95.62`, Caddy + WireGuard) has been **deleted**, and with it
**WireGuard altogether** — the tunnel is not coming back, and no WireGuard
configuration remains anywhere in this repo:

- `hosts/vps/` (all files, including the install runbook `README.md`)
- `hosts/homeserver/wireguard-client.nix` (the client end of the tunnel)
- `secrets/vps.yaml`, `secrets/homeserver.yaml`, `.sops.yaml`,
  `secrets.sudoers`
- the `sops-nix` flake input and module wiring, and the `vps`
  `nixosConfigurations` output

**Consequence: Plex remote access no longer works.** The homeserver is
behind carrier NAT and has no inbound ports, so Plex is reachable only on
the LAN. The intended replacement is **Tailscale**, which the homeserver
already runs (`services.tailscale.enable = true` in
`hosts/homeserver/default.nix`). Tailscale is to be set up later; do not
reintroduce WireGuard or a public reverse proxy to solve this. Ask before
adding anything.

## Repo layout

| Path | Notes |
|---|---|
| `flake.nix` | One host via `mkSystem`; nixpkgs = nixos-unstable |
| `hosts/homeserver/` | `default.nix` only |
| `modules/services/plex.nix` | Plex, GPU transcoding, read-only media ACLs |
| `scripts/update-check.sh` | current vs booted generation, next timer, reboot pending |
| `dev-mode.sh` | remote build helper (`check`/`build`/`eval`/`apply`); delegates to the homeserver |
| `hardware-configuration.nix` | Homeserver root/ESP by UUID |

## Verification before committing

```bash
# 1. Mirror your working tree to the homeserver (ALWAYS --delete).
rsync -avz --delete --exclude '.git' --exclude '*.iso' --exclude '*.iso.sha256' \
  . homeserver:~/nixos-config/

# 2. Evaluate and BUILD (flake check alone does not build the system).
ssh homeserver 'cd ~/nixos-config && nix flake check'
ssh homeserver 'cd ~/nixos-config && nix build --no-link \
  .#nixosConfigurations.homeserver.config.system.build.toplevel'

# 3. No plaintext secret may be added (must print 0).
git diff --cached | grep -cE '^\+[A-Za-z0-9+/]{43}=$'
```

Confirm intent by evaluating, not by reading:

```bash
ssh homeserver 'cd ~/nixos-config && nix eval --json \
  .#nixosConfigurations.homeserver.config.system.autoUpgrade'
```

`nix flake check` only evaluates the `nixosConfigurations` output; it does
**not** build the system closure. The `nix build` line above is the same
command CI runs, so a green run here means the CI gate will pass.

## Style

- Comments should explain **why**, especially where a value looks wrong
  (MTU 1380, no PSK, wide reboot windows). Several comments in this repo
  exist specifically to stop a future agent "fixing" a deliberate choice.
- Prefer declarative over imperative. If something is only configured on a
  live host and not in git, treat that as a bug.
