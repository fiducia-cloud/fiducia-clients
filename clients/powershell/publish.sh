#!/usr/bin/env sh
# Package/build/validate/release entrypoint for the PowerShell Fiducia client (see clients/PUBLISHING.md).
set -eu

# Surface-contract gate: refuse to publish a client whose exported
# interface has drifted from contract/surface.contract.json.
"$(cd "$(dirname "$0")/../.." && pwd)/contract/bin/prepublish-guard.sh" "$(basename "$(cd "$(dirname "$0")" && pwd)")"
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/../../scripts/publish-common.sh"
publish_parse_mode "$@"
cd "$DIR"
publish_check_version Fiducia.psd1 'ModuleVersion'
pwsh -NoLogo -NoProfile -Command 'Test-ModuleManifest ./Fiducia.psd1 | Out-Null'
[ "$PUBLISH_MODE" = dry-run ] || { publish_require POWERSHELL_GALLERY_API_KEY; pwsh -NoLogo -NoProfile -Command 'Publish-Module -Path . -Repository PSGallery -NuGetApiKey $env:POWERSHELL_GALLERY_API_KEY'; }
