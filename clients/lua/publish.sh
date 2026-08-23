#!/usr/bin/env sh
# Package/build/validate/release entrypoint for the Lua Fiducia client (see clients/PUBLISHING.md).
set -eu

# Surface-contract gate: refuse to publish a client whose exported
# interface has drifted from contract/surface.contract.json.
"$(cd "$(dirname "$0")/../.." && pwd)/contract/bin/prepublish-guard.sh" "$(basename "$(cd "$(dirname "$0")" && pwd)")"
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/../../scripts/publish-common.sh"
publish_parse_mode "$@"
cd "$DIR"
publish_require_version; rockspec="fiducia-client-$PACKAGE_VERSION-1.rockspec"; test -f "$rockspec"; luarocks lint "$rockspec"
[ "$PUBLISH_MODE" = dry-run ] || { publish_require LUAROCKS_API_KEY; luarocks upload "$rockspec" --api-key="$LUAROCKS_API_KEY"; }
