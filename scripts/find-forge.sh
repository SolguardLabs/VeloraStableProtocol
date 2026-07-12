#!/usr/bin/env bash
set -euo pipefail

if command -v forge >/dev/null 2>&1; then
  command -v forge
  exit 0
fi

if command -v forge.exe >/dev/null 2>&1; then
  command -v forge.exe
  exit 0
fi

for candidate in "$HOME/.foundry/bin/forge" "$HOME/.foundry/bin/forge.exe"; do
  if [[ -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    exit 0
  fi
done

echo "forge executable not found. Install Foundry or add forge to PATH." >&2
exit 127
