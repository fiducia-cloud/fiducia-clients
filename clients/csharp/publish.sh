#!/usr/bin/env sh
# Package/build/validate/release entrypoint for the C# Fiducia client (see clients/PUBLISHING.md).
set -eu

# Surface-contract gate: refuse to publish a client whose exported
# interface has drifted from contract/surface.contract.json.
"$(cd "$(dirname "$0")/../.." && pwd)/contract/bin/prepublish-guard.sh" "$(basename "$(cd "$(dirname "$0")" && pwd)")"
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/../../scripts/publish-common.sh"
publish_parse_mode "$@"
cd "$DIR"
publish_check_version Fiducia.Client.csproj '<Version>'
tmp="$(mktemp -d "${TMPDIR:-/tmp}/fiducia-csharp.XXXXXX")"; dotnet pack -c Release --output "$tmp"
[ "$PUBLISH_MODE" = dry-run ] || { publish_require NUGET_API_KEY; dotnet nuget push "$tmp"/*.nupkg --source https://api.nuget.org/v3/index.json --api-key "$NUGET_API_KEY" --skip-duplicate; }
