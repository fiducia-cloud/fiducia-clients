#!/usr/bin/env sh
set -eu
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/../../scripts/publish-common.sh"
publish_parse_mode "$@"
cd "$DIR"
gradle publishToMavenLocal --no-daemon
[ "$PUBLISH_MODE" = dry-run ] || { gradle publish --no-daemon; }
