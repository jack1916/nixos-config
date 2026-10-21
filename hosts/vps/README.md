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
| `disko.nix` | `/dev/sda`: GPT → 512M vfat `/boot` (EFI00) + ext4 `/` |
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

## 3. Add your SSH key before installing

`hosts/vps/default.nix` ships with an empty `authorizedKeys` list and
password auth disabled. Add your public key **now**, otherwise you cannot
log in after `nixos-anywhere` reboots:

```nix
openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAA... you@laptop" ];
```

## 4. Install the VPS with nixos-anywhere

The VPS provider boots a rescue/installer image as root. `disko` wipes
`/dev/sda` — double-check the disk before running.

```bash
nix run github:nix-community/nixos-anywhere -- \
  --flake .#vps \
  root@2.31.95.62
```

Useful extras:

```bash
# Skip kexec (some providers block it) and reboot into their image instead
nix run github:nix-community/nixos-anywhere -- \
  --flake .#vps --no-kexec root@2.31.95.62

# Also copy this host's age key into place in the same run
nix run github:nix-community/nixos-anywhere -- \
  --flake .#vps --extra-files ./vps-extra-files root@2.31.95.62
```

To inspect what disko would do without touching the disk (run **on the
VPS**, since it reads the real block devices):

```bash
nix run .#disko -- --mode dry-activate --flake .#vps
```

## 5. Deploy the homeserver side

The homeserver keeps its existing Plex setup; the only new piece is the
WireGuard client module. Per `AGENTS.md`, builds happen on the server:

```bash
rsync -avz --exclude '.git' . homeserver:~/nixos-config/
ssh homeserver "cd ~/nixos-config && sudo nixos-rebuild switch --flake .#homeserver"
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

## Operational notes

- **Caddy reloads, not restarts**, on config change (`enableReload`
  defaults to true), so `globalConfig` keeps the admin API enabled and only
  sets `grace_period 30s` to stop reloads hanging on long media streams.
- **MTU 1420** on both peers (1500 − 80 bytes WireGuard/IPv4/UDP overhead).
- **Plex "Remote Access" should be left OFF.** Advertising the carrier-NAT
  address is exactly what this tunnel avoids; clients reach Plex via
  `plex.9485432.xyz`.
