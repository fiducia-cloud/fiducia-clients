#!/usr/bin/env sh
set -eu
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/../../scripts/publish-common.sh"
publish_parse_mode "$@"
cd "$DIR"
publish_check_version fiducia-client.cabal '^version:'
tmp="$(mktemp -d "${TMPDIR:-/tmp}/fiducia-haskell.XXXXXX")"; cabal check; cabal sdist --output-dir "$tmp"
[ "$PUBLISH_MODE" = dry-run ] || { cabal upload --publish "$tmp"/*.tar.gz; }
