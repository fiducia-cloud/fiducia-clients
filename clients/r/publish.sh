#!/usr/bin/env sh
# Package/build/validate/release entrypoint for the R Fiducia client (see clients/PUBLISHING.md).
set -eu
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/../../scripts/publish-common.sh"
publish_parse_mode "$@"
cd "$DIR"
publish_check_version DESCRIPTION '^Version:'
R CMD check --as-cran .
[ "$PUBLISH_MODE" = dry-run ] || { R CMD build .; }
