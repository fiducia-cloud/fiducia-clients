#!/usr/bin/env sh
# Package/build/validate/release entrypoint for the Dart Fiducia client (see clients/PUBLISHING.md).
set -eu

# Surface-contract gate: refuse to publish a client whose exported
# interface has drifted from contract/surface.contract.json.
"$(cd "$(dirname "$0")/../.." && pwd)/contract/bin/prepublish-guard.sh" "$(basename "$(cd "$(dirname "$0")" && pwd)")"
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/../../scripts/publish-common.sh"
publish_parse_mode "$@"
cd "$DIR"
publish_check_version pubspec.yaml '^version:'
tmp="$(mktemp -d "${TMPDIR:-/tmp}/fiducia-dart.XXXXXX")"; mkdir -p "$tmp/lib"; cp fiducia.dart "$tmp/lib/fiducia_client.dart"; cp pubspec.yaml LICENSE README.md CHANGELOG.md "$tmp/"; cd "$tmp"; dart pub publish --dry-run
[ "$PUBLISH_MODE" = dry-run ] || { dart pub publish --force; }
