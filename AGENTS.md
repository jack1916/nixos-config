# AGENTS.md - NixOS Home Server Config

## Architecture Rules
- DO NOT run full `nix` builds locally. This laptop only has Pacman Nix (experimental, not recommended for production).
- Use the home server for actual builds, formatting checks, and rebuilds via SSH.
- **Local dry-runs allowed for testing**: flake validation, syntax checking, evaluation-only operations.

## SSH Configuration
- The `homeserver` alias in `~/.ssh/config` points to your nixos home server:
  - Connect via: `ssh homeserver`
- See `~/.ssh/config` for the full host entry and details about the server hostname and IP.

## Development Workflows

### Local Evaluation (Safe Dry-Runs)
These commands validate without building or applying changes:
- `cd ~/nixos-config && nix flake check` - Validate all inputs and outputs
- `nix flake show` - Inspect flake output structure
- `~/Projects/nixos-config/dev-mode.sh eval` - Run the development helper script

### Local Flake Inspection Commands
```bash
# List available system configurations (attr names)
nix eval .#nixosConfigurations --apply builtins.attrNames --json

# Inspect a specific option value
nix eval --raw .#nixosConfigurations.homeserver.config.networking.hostName

# Resolve the full system toplevel derivation path (evaluation only, no build)
nix eval --raw .#nixosConfigurations.homeserver.config.system.build.toplevel.drvPath
```

### Remote Dry-Run Build (Recommended for Testing)
Sync then test on the home server:
```bash
rsync -avz --exclude '.git' . homeserver:~/nixos-config/ \
  && ssh homeserver "cd ~/nixos-config && nixos-rebuild dry-build --flake .#homeserver"
```

### Remote Apply Build (Production)
Apply the configuration to your home server:
```bash
rsync -avz --exclude '.git' . homeserver:~/nixos-config/ \
  && ssh homeserver "cd ~/nixos-config && nixos-rebuild switch"
```

### Formatting Check (Remote)
Sync then check formatting:
```bash
rsync -avz --exclude '.git' . homeserver:~/nixos-config/ \
  && ssh homeserver "cd ~/nixos-config && nixfmt --check ."
```

## Dev Mode Helper Script
Use `~/Projects/nixos-config/dev-mode.sh` for development tasks:
- Syntax validation only (safe local testing)
- Flake output inspection
- Evaluation-only dry-runs (resolves the toplevel derivation path without building)
- Conditional build verification via `nix flake check`

Commands:
```bash
cd ~/Projects/nixos-config && ./dev-mode.sh eval               # Evaluate and inspect flake structure
cd ~/Projects/nixos-config && ./dev-mode.sh dry-run homeserver # Evaluation-only dry-run
cd ~/Projects/nixos-config && ./dev-mode.sh apply              # Run local tests (flake check)
cd ~/Projects/nixos-config && ./dev-mode.sh outputs            # List flake outputs
```

## Quick Reference

| Task | Command |
|------|---------|
| Validate flake syntax locally | `cd ~/nixos-config && nix flake check` |
| Inspect flake outputs | `nix flake show` |
| Format check (remote) | `rsync ... && ssh homeserver "nixfmt --check ."` |
| Dry-build test (remote) | `rsync ... && ssh homeserver "nixos-rebuild dry-build --flake .#homeserver"` |
| Apply to server | `rsync ... && ssh homeserver "nixos-rebuild switch"` |
