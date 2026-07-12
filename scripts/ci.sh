#!/usr/bin/env bash
set -euo pipefail

FORGE_BIN="$(bash scripts/find-forge.sh)"

bash scripts/bootstrap.sh
"$FORGE_BIN" fmt --check
"$FORGE_BIN" build
"$FORGE_BIN" test
