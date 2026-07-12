#!/usr/bin/env sh
set -eu
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/../../scripts/publish-common.sh"
publish_parse_mode "$@"
cd "$DIR"
publish_check_version package.json '"version"'
npm pack --dry-run
[ "$PUBLISH_MODE" = dry-run ] || { npm publish --access public; }
