#!/usr/bin/env sh
set -eu
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/../../scripts/publish-common.sh"
publish_parse_mode "$@"
cd "$DIR"
publish_check_version Fiducia.psd1 'ModuleVersion'
pwsh -NoLogo -NoProfile -Command 'Test-ModuleManifest ./Fiducia.psd1 | Out-Null'
[ "$PUBLISH_MODE" = dry-run ] || { publish_require POWERSHELL_GALLERY_API_KEY; pwsh -NoLogo -NoProfile -Command 'Publish-Module -Path . -Repository PSGallery -NuGetApiKey $env:POWERSHELL_GALLERY_API_KEY'; }
