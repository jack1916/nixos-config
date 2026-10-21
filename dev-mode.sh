#!/bin/bash
# Development mode helper for local NixOS flake testing.
#
# Per AGENTS.md: this laptop only runs EVALUATION-ONLY operations.
# Real builds and rebuilds happen on the home server via SSH.
set -euo pipefail

# Directory containing this script (the flake root).
FLAKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
Usage: $0 {eval|dry-run|apply|outputs} [target]

Commands:
  $0 eval              Evaluate the flake and show its structure
  $0 dry-run [target]  Evaluation-only dry-run for a nixosConfigurations target (default: homeserver)
  $0 apply             Run local tests (nix flake check)
  $0 outputs           List available flake outputs

Note: Full builds and rebuilds must be run on the home server via SSH:
  rsync -avz --exclude '.git' "$FLAKE_DIR" homeserver:~/nixos-config/
  ssh homeserver "cd ~/nixos-config && nixos-rebuild dry-build --flake .#homeserver"
  ssh homeserver "cd ~/nixos-config && nixos-rebuild switch"
EOF
}

# Evaluate the flake and print its output structure.
eval_flake() {
    echo "=== Evaluating flake at $FLAKE_DIR ==="
    nix flake show "$FLAKE_DIR"
}

# Evaluation-only dry-run: resolve the toplevel derivation path, which
# evaluates the full system configuration without building anything.
dry_run() {
    local target="${1:-homeserver}"
    echo "=== Evaluation-only dry-run: nixosConfigurations.${target} ==="
    local drv
    drv="$(nix eval --raw "$FLAKE_DIR#nixosConfigurations.${target}.config.system.build.toplevel.drvPath")"
    echo "Would build: $drv"
    echo ""
    echo "To dry-build remotely:"
    echo "  rsync -avz --exclude '.git' \"$FLAKE_DIR\" homeserver:~/nixos-config/"
    echo "  ssh homeserver \"cd ~/nixos-config && nixos-rebuild dry-build --flake .#homeserver\""
}

# Run local validation tests (flake check). Does not build or apply anything.
apply_local() {
    echo "=== Running nix flake check (local, validation only) ==="
    nix flake check "$FLAKE_DIR"
    echo "=== Flake check passed ==="
    echo ""
    echo "To apply on the home server:"
    echo "  rsync -avz --exclude '.git' \"$FLAKE_DIR\" homeserver:~/nixos-config/"
    echo "  ssh homeserver \"cd ~/nixos-config && nixos-rebuild switch\""
}

# List available flake outputs.
show_outputs() {
    echo "=== Available flake outputs ==="
    nix flake show "$FLAKE_DIR"
}

case "${1:-}" in
    eval)        eval_flake ;;
    dry-run)     dry_run "${2:-}" ;;
    apply|build) apply_local ;;
    outputs)     show_outputs ;;
    -h|--help)   usage ;;
    "")          usage ;;
    *)           usage; exit 1 ;;
esac
