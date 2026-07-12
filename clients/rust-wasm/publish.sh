#!/usr/bin/env sh
set -eu
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/../../scripts/publish-common.sh"
publish_parse_mode "$@"
cd "$DIR"
publish_check_version Cargo.toml '^version'
wasm-pack build --target bundler --release; npm pack --dry-run ./pkg
[ "$PUBLISH_MODE" = dry-run ] || { npm publish ./pkg --access public; }
