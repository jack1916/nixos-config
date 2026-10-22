# VPS Gateway — Plex over WireGuard

Public gateway that hides the homeserver's carrier-NAT address.

```
Internet ──443/TLS──▶ vps (2.31.95.62)
                       │  Caddy: plex.9485432.xyz → http://10.100.0.2:32400
                       │
                       └── wg0 10.100.0.1/24 ◀── WireGuard ──▶ wg0 10.100.0.2/24
                                                                  homeserver (Plex)
                                                                  keepalive 25s
```

Only `wg0` is a shared network. Client HTTP is proxied in userspace by
Caddy, so **no IP forwarding / NAT** is configured on either side.

## Layout

| File | Purpose |
|---|---|
| `hardware-configuration.nix` | Root/ESP filesystems by UUID (inherited Hetzner layout) |
| `wireguard.nix` | `wg0` on `10.100.0.1/24`, UDP 51820, single peer `10.100.0.2` |
| `caddy.nix` | ACME TLS for `plex.9485432.xyz`, reverse proxy to `:32400` |
| `default.nix` | Base system, SSH, firewall, sops, upgrades |
| `../homeserver/wireguard-client.nix` | Client side, `persistentKeepalive = 25` |

Effective firewall on the VPS: **tcp 22, 80, 443** and **udp 51820**.
Everything else inbound is dropped.

## 1. Generate WireGuard keys

Run on the VPS (or any trusted machine). Never commit the `.private` file.

```bash
umask 077
wg genkey > vps.private
wg pubkey < vps.private > vps.public

wg genkey > homeserver.private
wg pubkey < homeserver.private > homeserver.public
```

> A PSK (`wg genpsk`) is **not** used here — both peers authenticate with
> Curve25519 public keys only. If you ever add one, it must be configured
> on *both* sides simultaneously, otherwise the handshake silently fails.

Record the two **public** keys:

```bash
echo "VPS public:        $(cat vps.public)"
echo "Homeserver public: $(cat homeserver.public)"
```

Then replace the placeholders in git (public keys are not secret):

- `hosts/vps/wireguard.nix` → `publicKey = "<homeserver.public contents>";`
- `hosts/homeserver/wireguard-client.nix` → `publicKey = "<vps.public contents>";`

Mind the crossing: each host's *own* public key goes in the *other* host's
config.

## 2. Store the private keys with sops

The private keys go into the encrypted files already referenced by the
configs: `secrets/vps.yaml` and `secrets/homeserver.yaml`.

```bash
# One-time: create an age key per host, or reuse an existing key.
# The key must live at /var/lib/sops-nix/key.txt on each machine.
age-keygen -o age-homeserver.txt      # prints "Public key: age1..."
ssh root@2.31.95.62 'install -d -m 0700 /var/lib/sops-nix'
scp age-homeserver.txt root@2.31.95.62:/var/lib/sops-nix/key.txt
```

Create/edit the encrypted files (keys are read from these paths):

```bash
sops secrets/vps.yaml
# wireguard_private_key: <contents of vps.private>

sops secrets/homeserver.yaml
# wireguard_private_key: <contents of homeserver.private>
```

Add each host's age **public** key to `.sops.yaml` at the repo root so
`sops` encrypts for the right recipients, e.g.:

```yaml
creation_rules:
  - path_regex: secrets/vps\.yaml$
    key_groups:
      - age: [ "age1...VPS_RECIPIENT..." ]
  - path_regex: secrets/homeserver\.yaml$
    key_groups:
      - age: [ "age1...HOMESERVER_RECIPIENT..." ]
```

Then `sops updatekeys secrets/vps.yaml` after editing `.sops.yaml`.

Delegate the private keys at runtime:

- VPS → `/run/secrets/wireguard/vps-private-key`
- Homeserver → `/run/secrets/wireguard/homeserver-private-key`

These paths are produced by `sops-nix` from the `sops.secrets` definitions;
verify with `sudo cat /run/secrets/wireguard/...` after the first switch.

## 3. Confirm the SSH keys in the config

`hosts/vps/default.nix` already lists the laptop key for **both `root` and
`jack`**, and disables password auth. `nixos-anywhere` and the install
steps connect as `root`, so the root entry is the one that matters for
recovery.

If you change machines, update both lists before deploying — otherwise the
switch will lock you out:

```nix
users.users.root.openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAA... you@laptop" ];
users.users.jack.openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAA... you@laptop" ];
```

`nixos-infect` separately scrapes `/root/.ssh/authorized_keys` from the
Ubuntu image, so make sure your key is selected when rebuilding in 4a.

## 4. Install the VPS

### Why not nixos-anywhere

Two hard constraints on Hetzner x86_64 cloud VMs, both verified on a real
instance:

1. **Legacy BIOS boot.** `kexec` fails with `PEFILE: Unsigned PE binary`
   and there is no way to enable it. Not transient.
2. **Skipping kexec is destructive.** `--phases disko,install,reboot`
   (there is no `--no-kexec` flag) repartitions the disk that is currently
   mounted as `/`. The kernel will not reload the partition table of an
   in-use disk, so disko rewrites the GPT and zeroes the MBR without being
   able to create filesystems: the machine is left **unbootable**. This
   happened. Recover with the Hetzner console's Rebuild.

`nixos-infect` avoids both: it converts the running Ubuntu **in place**, so
no kexec, no ISO, no partitioning.

### Trade-off

Partitioning is no longer declared in this repo. The machine keeps
Hetzner's layout (`sda1` root, `sda14` bios_grub, `sda15` ESP), and
`hardware-configuration.nix` records those UUIDs. **Recreating or
rebuilding the server changes the UUIDs** — update that file or the system
will not boot.

### 4a. Rebuild the server as Ubuntu

Hetzner console → your server → **Rebuild** → Ubuntu → confirm. Select your
SSH key so root login works. A few minutes.

Confirm the result:

```bash
ssh root@2.31.95.62 'lsblk -f /dev/sda; [ -d /sys/firmware/efi ] && echo UEFI || echo BIOS'
```

Expect `sda1` ext4 on `/` and **BIOS**. Note the UUIDs and check they match
`hosts/vps/hardware-configuration.nix`; update it if they differ.

### 4b. Run nixos-infect

```bash
ssh root@2.31.95.62
curl -sfL https://raw.githubusercontent.com/elitak/nixos-infect/master/nixos-infect \
  -o /tmp/nixos-infect
NO_REBOOT=1 bash /tmp/nixos-infect      # inspect before rebooting
```

`NO_REBOOT=1` lets you look at the generated config first. It writes:

- `/etc/nixos/configuration.nix`
- `/etc/nixos/hardware-configuration.nix`
- `/etc/nixos/networking.nix` — the Hetzner `/32` address + onlink gateway

Check `networking.nix` contains your real address and gateway, then:

```bash
reboot
```

### 4c. Verify NixOS booted

```bash
ssh -o StrictHostKeyChecking=no root@2.31.95.62 \
  '. /etc/os-release; echo $PRETTY_NAME; ls /etc/nixos/'
```

### 4d. Switch to this flake

The generated `/etc/nixos/networking.nix` must stay in the import chain,
because this flake deliberately sets `networking.useDHCP = false` (see the
comment in `default.nix`). Copy it into the flake, or import it from
`default.nix`.

```bash
# From your laptop: send the flake
rsync -avz --exclude '.git' --exclude '*.iso' \
  ~/Projects/nixos-config/ root@2.31.95.62:/etc/nixos-config/

# On the VPS: carry the generated networking across, then switch
ssh root@2.31.95.62
cp /etc/nixos/networking.nix /etc/nixos-config/hosts/vps/networking.nix
# add  ./networking.nix  to the imports list in hosts/vps/default.nix
nixos-rebuild switch --flake /etc/nixos-config#vps
```

Switching enables sops, so the age key must already be installed
(step 5 below) or `sops-install-secrets` will fail.

## 5. Install the age keys and deploy the homeserver

### 5a. Age key on the VPS (do this BEFORE the 4d switch)

`sops-install-secrets` runs during the switch and cannot decrypt the
WireGuard private key without this file. Path must match
`sops.age.keyFile` in `hosts/vps/default.nix`.

```bash
scp ~/age-keys/vps.txt root@2.31.95.62:/tmp/ak.txt
ssh root@2.31.95.62 'install -d -m 0700 /var/lib/sops-nix && \
  install -m 0400 /tmp/ak.txt /var/lib/sops-nix/key.txt && rm -f /tmp/ak.txt'
```

### 5b. Deploy the homeserver

The homeserver keeps its existing Plex setup; the only new piece is the
WireGuard client module. Per `AGENTS.md`, builds happen on the server:

```bash
rsync -avz --exclude '.git' . homeserver:~/nixos-config/
ssh homeserver "cd ~/nixos-config && sudo nixos-rebuild switch --flake .#homeserver"
```

The homeserver already has its age key at `/var/lib/sops-nix/key.txt`.
Verify the tunnel came up:

```bash
ssh homeserver 'sudo systemctl status sops-install-secrets --no-pager; sudo wg show'
```

## 6. Verify

```bash
# On the VPS — handshake should show a recent timestamp
sudo wg show

# From the VPS — Plex must answer across the tunnel
curl -sI http://10.100.0.2:32400/web | head -1

# From anywhere — public TLS endpoint
curl -sI https://plex.9485432.xyz/web | head -1

# Cert issuance / renewal
sudo journalctl -u caddy -b | grep -i acme
```

`wg show` on the homeserver must report `persistent keepalive: every 25 seconds`.
If the handshake never completes, confirm UDP 51820 is open and that
`2.31.95.62` is the address the VPS actually has:

```bash
sudo nft list ruleset | grep 51820
curl -s https://ifconfig.me
```

## 7. Keeping machines patched

Fully automatic, with a build gate. Nothing waits on a human.

```
CI (daily 02:00 UTC)
     → nix flake update
     → BUILD BOTH HOSTS          ← the gate
     → if both build: commit flake.lock to main
     → if either fails: nothing is committed, workflow fails loudly
main branch  → flake.lock advances
     ↓            machines pull from GitHub
homeserver   →  nightly 03:00 (+15m jitter), reboots in 03:00-05:00
vps          →  nightly 03:00 (+10m jitter), reboots in 03:00-04:30
```

Patches reach the machines within roughly 24h of upstream. There is no PR
to merge: the daily commit lands on `main` directly, and `build.yml`
builds again on that push as a second check.

### Reboots are conditional, not nightly

`allowReboot` does **not** mean a reboot every night. The service runs
`nixos-rebuild boot`, then compares the booted against the built
kernel/initrd/kernel-modules. It reboots **only if those changed**;
otherwise it does a plain `switch` and leaves the machine running. So a
reboot happens only when a reboot is actually needed to apply a patch.

Two things to be careful of if you edit the schedule:

- **`rebootWindow` must contain the run time.** The service compares the
  wall clock against the window and, if it is outside it, skips the reboot
  *silently* and defers to the next run.
- **Leave slack for the random delay plus the rebuild.** Narrowing the
  window to just the delay can cause reboots to be deferred indefinitely.
  The VPS window is 03:00-04:30 for this reason: it covers a 10 minute
  jitter plus a full rebuild.

### Why it is set up this way

`system.autoUpgrade` previously pointed at a local path
(`/home/jack/nixos-config/`). That silently did nothing: `flake.lock` is
pinned, and without a `git pull` the nightly rebuild just reproduced the
same closure. **No security patches ever arrived.**

Both hosts now use `github:jack1916/nixos-config#<host>`, which re-checks
the ref (`--refresh` is added automatically) and picks up whatever is on
`main`.

Do **not** add `--update-input nixpkgs` to either host. That would let the
machine resolve its own nixpkgs and bypass the CI build gate below.

### The CI gate

`update-flake.yml` runs daily at 02:00 UTC. It runs `nix flake update`,
then **builds both hosts**. Only if both succeed does it commit
`flake.lock` and push to `main`. If a dependency bump breaks either host,
the workflow fails and **nothing is committed** — so the machines never
see an untested lock.

It also skips the commit entirely when `flake.lock` is already current, so
there is no daily commit when nothing moved upstream.

`build.yml` builds both hosts again on every push and PR, so a bad manual
commit cannot reach `main` unnoticed either.

### If an update breaks something

The build gate catches most problems before they ship, but not all (a
runtime regression can still compile). If a machine ends up broken:

```bash
ssh root@<host> 'nixos-rebuild --rollback switch'
```

Or revert the offending lock commit:

```bash
cd ~/Projects/nixos-config
git revert <commit> && git push
```

Machines pick up the reverted lock on their next 03:00 run. Garbage
collection keeps 30 days on the homeserver and 14 days on the VPS, so
rollback generations remain available for that long.

To update on demand without waiting for the schedule, run the workflow
manually from the Actions tab (`workflow_dispatch`), or locally:

```bash
nix flake update && git add flake.lock && git commit -m "chore: update flake.lock" && git push
```

### Checking for pending reboots

Both hosts reboot themselves when a patch requires it, but it is still
worth checking what is pending:

```bash
scripts/update-check.sh              # both hosts
scripts/update-check.sh vps
```

It reports the current vs booted generation, the next autoUpgrade run, and
whether a reboot is pending. If a reboot was deferred (for example the
service finished outside its window), apply it by hand:

```bash
ssh root@2.31.95.62 systemctl reboot
```

## Operational notes

- **Caddy reloads, not restarts**, on config change (`enableReload`
  defaults to true), so `globalConfig` keeps the admin API enabled and only
  sets `grace_period 30s` to stop reloads hanging on long media streams.
- **MTU 1380** on both peers, NOT the usual 1420. PMTU probing showed
  payloads above 1364 bytes were dropped on the carrier-NAT path, which
  made large transfers hang while small ones worked. See the comment in
  `wireguard.nix`.
- **Plex "Remote Access" should be left OFF.** Advertising the carrier-NAT
  address is exactly what this tunnel avoids; clients reach Plex via
  `plex.9485432.xyz`.
