$ErrorActionPreference = "Stop"

forge fmt --check
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

forge build
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

forge test
exit $LASTEXITCODE

