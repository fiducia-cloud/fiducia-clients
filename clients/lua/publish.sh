#!/usr/bin/env sh
set -eu
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/../../scripts/publish-common.sh"
publish_parse_mode "$@"
cd "$DIR"
publish_require_version; rockspec="fiducia-client-$PACKAGE_VERSION-1.rockspec"; test -f "$rockspec"; luarocks lint "$rockspec"
[ "$PUBLISH_MODE" = dry-run ] || { publish_require LUAROCKS_API_KEY; luarocks upload "$rockspec" --api-key="$LUAROCKS_API_KEY"; }
