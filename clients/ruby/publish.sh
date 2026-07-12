#!/usr/bin/env sh
set -eu
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/../../scripts/publish-common.sh"
publish_parse_mode "$@"
cd "$DIR"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/fiducia-ruby.XXXXXX")"
gem_file="$tmp/fiducia-client.gem"
gem build fiducia-client.gemspec --output "$gem_file"
gem specification "$gem_file" >/dev/null
[ "$PUBLISH_MODE" = dry-run ] || { gem push "$gem_file"; }
