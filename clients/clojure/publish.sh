#!/usr/bin/env sh
set -eu
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/../../scripts/publish-common.sh"
publish_parse_mode "$@"
cd "$DIR"
publish_check_version build.clj 'def version'
clojure -T:build jar
[ "$PUBLISH_MODE" = dry-run ] || { clojure -T:build deploy; }
