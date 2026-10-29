#!/bin/bash
# Remote build helper for the NixOS flake.
#
# The laptop CANNOT run `nix` (it has no /nix/store — see AGENTS.md, "Local
# Nix is broken"). Every command here therefore delegates to the homeserver.
#
# It syncs the working tree to a PLAIN rsync target on the homeserver and
# builds there. That target (~/nixos-config, also reachable as /etc/nixos)
# is deliberately NOT a git repo, so there is no staging step and no
# "Git tree is dirty" ambiguity. See AGENTS.md, "Where the source of truth
# is".
#
# Always synced with --delete: files removed locally must not linger and be
# built. (A deleted hosts/vps/ once kept reappearing in builds this way.)
set -euo pipefail

FLAKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE="${REMOTE:-homeserver}"
HOST="homeserver"

TOPPLEV=".#nixosConfigurations.${HOST}.config.system.build.toplevel"

sync() {
    echo "=== rsync --delete -> ${REMOTE}:~/nixos-config ==="
    rsync -avz --delete \
        --exclude '.git' --exclude '*.iso' --exclude '*.iso.sha256' \
        "${FLAKE_DIR}/" "${REMOTE}:~/nixos-config/"
}

usage() {
    cat <<EOF
Usage: $0 {check|build|eval|apply|outputs}

Commands:
  $0 check     nix flake check on the homeserver (evaluate only)
  $0 build     Build the homeserver toplevel on the homeserver (CI's gate)
  $0 eval      Show the flake output structure on the homeserver
  $0 apply     Build, then switch the homeserver to it (one-shot apply)
  $0 outputs   Alias for eval

Every command first rsyncs your working tree to ${REMOTE}:~/nixos-config.
Override the target with REMOTE=<ssh-host> $0 ...
EOF
}

remote_nix() {
    ssh "${REMOTE}" "cd ~/nixos-config && $*"
}
check() {
    sync
    echo "=== nix flake check (remote) ==="
    remote_nix "nix flake check"
}

build() {
    sync
    echo "=== nix build ${HOST} toplevel (remote, same as CI gate) ==="
    remote_nix "nix build --no-link --print-out-paths '${TOPPLEV}'"
}

eval_flake() {
    sync
    echo "=== nix flake show (remote) ==="
    remote_nix "nix flake show"
}

apply() {
    sync
    echo "=== nixos-rebuild switch --flake .#${HOST} (remote) ==="
    remote_nix "sudo nixos-rebuild switch --flake .#${HOST}"
}

case "${1:-}" in
    check)         check ;;
    build)         build ;;
    eval|outputs)  eval_flake ;;
    apply)         apply ;;
    -h|--help)     usage ;;
    "")            usage ;;
    *)             usage; exit 1 ;;
esac
