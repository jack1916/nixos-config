#!/usr/bin/env bash
# Update status helper.
#
# Machines pull the flake from GitHub automatically:
#   homeserver: nightly 03:00, reboots itself inside 03:00-05:00
#   vps:        nightly 04:00, NEVER reboots automatically
#
# Use this to see whether anything is pending, especially on the VPS where
# a reboot needs doing by hand.
#
# Usage:
#   scripts/update-check.sh            # check both hosts
#   scripts/update-check.sh homeserver
#   scripts/update-check.sh vps
set -euo pipefail

hosts=("$@")
if [ ${#hosts[@]} -eq 0 ]; then
  hosts=(homeserver vps)
fi

for host in "${hosts[@]}"; do
  echo "=============================================================="
  echo "  $host"
  echo "=============================================================="

  if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$host" true 2>/dev/null; then
    echo "  UNREACHABLE"
    echo
    continue
  fi

  ssh -o ConnectTimeout=10 -o BatchMode=yes "$host" bash -s <<'REMOTE'
    echo "--- generation ---"
    current=$(readlink /run/current-system)
    booted=$(readlink /run/booted-system)
    echo "  current:  $(echo "$current" | grep -o 'nixos-system-[a-z0-9.-]*' | head -1)"
    echo "  booted:   $(echo "$booted" | grep -o 'nixos-system-[a-z0-9.-]*' | head -1)"
    echo "  running kernel: $(uname -r)"

    echo "--- last autoUpgrade run ---"
    if systemctl list-units --all --no-legend 'nixos-upgrade*' 2>/dev/null | grep -q nixos-upgrade; then
      systemctl status nixos-upgrade.service --no-pager 2>/dev/null \
        | grep -E "Active:|TriggeredBy:" | sed 's/^/  /' || true
    fi
    # The timer is what schedules it; report the next elapse
    systemctl list-timers 'nixos-upgrade*' --no-pager 2>/dev/null \
      | grep nixos-upgrade | sed 's/^/  /' || echo "  no nixos-upgrade timer found"

    echo "--- reboot required? ---"
    if [ "$current" != "$booted" ]; then
      echo "  YES - the current generation is not the booted one"
      echo "        reboot to apply:  systemctl reboot"
    else
      echo "  no - booted system matches the current generation"
    fi
REMOTE
  echo
done
