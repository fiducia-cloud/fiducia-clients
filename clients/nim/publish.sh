#!/usr/bin/env sh
# Package/build/validate/release entrypoint for the Nim Fiducia client (see clients/PUBLISHING.md).
set -eu
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/../../scripts/publish-common.sh"
publish_parse_mode "$@"
cd "$DIR"
publish_check_version fiducia.nimble '^version'
nimble check
[ "$PUBLISH_MODE" = dry-run ] || { nimble publish; }
