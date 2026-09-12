#!/usr/bin/env sh
# Package/build/validate/release entrypoint for the PHP Fiducia client (see clients/PUBLISHING.md).
set -eu

# Surface-contract gate: refuse to publish a client whose exported
# interface has drifted from contract/surface.contract.json.
"$(cd "$(dirname "$0")/../.." && pwd)/contract/bin/prepublish-guard.sh" "$(basename "$(cd "$(dirname "$0")" && pwd)")"
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/../../scripts/publish-common.sh"
publish_parse_mode "$@"
cd "$DIR"
publish_check_version composer.json '"version"'
composer validate --strict; composer archive
[ "$PUBLISH_MODE" = dry-run ] || { publish_require PACKAGIST_USERNAME; publish_require PACKAGIST_API_TOKEN; curl --fail --show-error --request POST "https://packagist.org/api/update-package?username=$PACKAGIST_USERNAME&apiToken=$PACKAGIST_API_TOKEN" --header "content-type: application/json" --data '{"repository":{"url":"https://github.com/fiducia-cloud/fiducia-clients"}}'; }
