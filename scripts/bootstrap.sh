#!/usr/bin/env bash
set -euo pipefail

FORGE="$(bash scripts/find-forge.sh)"

if [[ ! -f lib/forge-std/src/Test.sol || ! -f lib/forge-std/src/Script.sol ]]; then
  "$FORGE" install foundry-rs/forge-std@v1.9.6 --no-git --shallow
fi
