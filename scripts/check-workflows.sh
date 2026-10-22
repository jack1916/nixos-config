#!/usr/bin/env bash
# Syntax-check every `run:` block in the GitHub workflows.
#
# Why this exists: GitHub only reports a shell syntax error when the step
# actually executes, and a broken step can sit unnoticed until the exact
# branch it guards is taken. A quoting mistake in the "nothing changed"
# branch of update-flake.yml did exactly that - the daily runs that skip
# the commit never touched it, and it only surfaced on a force_build run.
#
# Two checks per block:
#   1. `bash -n` - catches the real failure shape (unbalanced quotes inside
#      an if/fi or { } group).
#   2. a quote-balance heuristic - `bash -n` does NOT catch a bare
#      unbalanced quote that simply runs to EOF, so this covers that gap.
#
# Neither is exhaustive, but between them they catch the mistakes that
# have actually happened here.
#
# Usage: scripts/check-workflows.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

python3 - <<'PY'
import re
import subprocess
import sys
import textwrap
from pathlib import Path

failures = 0

for path in sorted(Path(".github/workflows").glob("*.yml")) + \
            sorted(Path(".github/workflows").glob("*.yaml")):
    lines = path.read_text().split("\n")
    block = 0
    i = 0
    while i < len(lines):
        m = re.match(r"^(\s*)run:\s*\|", lines[i])
        if not m:
            i += 1
            continue
        indent = len(m.group(1))
        body = []
        i += 1
        while i < len(lines):
            line = lines[i]
            if line.strip() == "":
                body.append("")
                i += 1
                continue
            if len(line) - len(line.lstrip()) <= indent:
                break
            body.append(line)
            i += 1

        block += 1
        # `${{ ... }}` is substituted by GitHub before bash sees it; drop it
        # so expressions do not look like syntax errors.
        src = re.sub(r"\$\{\{[^}]*\}\}", "PLACEHOLDER", textwrap.dedent("\n".join(body)))

        problems = []

        proc = subprocess.run(["bash", "-n"], input=src, capture_output=True, text=True)
        if proc.returncode != 0:
            err = proc.stderr.strip().splitlines()
            problems.append(err[-1] if err else "bash -n failed")

        # Heuristic for the case bash -n misses: a bare unbalanced quote
        # running to EOF.
        #
        # Do NOT strip "#..." as a comment here. Strings such as
        #   echo "### No update needed"
        # contain a '#' inside quotes, and naive comment-stripping truncates
        # mid-string, producing a false positive (this happened). Instead
        # walk the line tracking quote state, so escaped quotes and
        # single-quoted regions are handled and '#' is only ignored when it
        # appears outside a double-quoted region.
        for n, line in enumerate(src.split("\n"), 1):
            stripped = line.strip()
            if stripped.startswith("#") or '"' not in line:
                continue
            in_dq = False
            in_sq = False
            # NOTE: use a distinct cursor name. Reusing `i` here clobbers
            # the outer line-index loop and makes the scanner restart
            # forever.
            pos = 0
            while pos < len(line):
                ch = line[pos]
                if ch == "\\" and pos + 1 < len(line):
                    pos += 2
                    continue
                if ch == "'" and not in_dq:
                    in_sq = not in_sq
                elif ch == '"' and not in_sq:
                    in_dq = not in_dq
                pos += 1
            if in_dq:
                problems.append(f"line {n}: unterminated double quote")

        if problems:
            failures += 1
            for p in problems:
                print(f"FAIL {path} run-block {block}: {p}")
            for n, line in enumerate(src.split("\n"), 1):
                print(f"  {n:3}| {line}")

    if block == 0:
        print(f"     {path}: no run: blocks found")

if failures:
    print(f"\n{failures} workflow run-block(s) failed syntax check")
    sys.exit(1)
print("all workflow run-blocks pass bash -n")
PY
