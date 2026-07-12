#!/usr/bin/env bash
set -euo pipefail

FORGE_BIN="$(bash scripts/find-forge.sh)"

bash scripts/bootstrap.sh
"$FORGE_BIN" test -vvv
