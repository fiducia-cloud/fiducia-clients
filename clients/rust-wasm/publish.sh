#!/usr/bin/env sh
# Package/build/validate/release entrypoint for the Rust->WebAssembly Fiducia client (see clients/PUBLISHING.md).
set -eu

# Surface-contract gate: refuse to publish a client whose exported
# interface has drifted from contract/surface.contract.json.
"$(cd "$(dirname "$0")/../.." && pwd)/contract/bin/prepublish-guard.sh" "$(basename "$(cd "$(dirname "$0")" && pwd)")"
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/../../scripts/publish-common.sh"
publish_parse_mode "$@"
cd "$DIR"
publish_check_version Cargo.toml '^version'
wasm-pack build --target bundler --release -- --locked; npm pack --dry-run ./pkg
[ "$PUBLISH_MODE" = dry-run ] || { npm publish ./pkg --access public; }
