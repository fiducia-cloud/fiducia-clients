#!/usr/bin/env sh
set -eu
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/../../scripts/publish-common.sh"
publish_parse_mode "$@"
cd "$DIR"
R CMD check --as-cran .
[ "$PUBLISH_MODE" = dry-run ] || { R CMD build .; }
