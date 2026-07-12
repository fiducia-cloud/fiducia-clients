#!/usr/bin/env sh
# Package/build/validate/release entrypoint for the PHP Fiducia client (see clients/PUBLISHING.md).
set -eu
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/../../scripts/publish-common.sh"
publish_parse_mode "$@"
cd "$DIR"
publish_check_version composer.json '"version"'
composer validate --strict; composer archive
[ "$PUBLISH_MODE" = dry-run ] || { publish_require PACKAGIST_USERNAME; publish_require PACKAGIST_API_TOKEN; curl --fail --show-error --request POST "https://packagist.org/api/update-package?username=$PACKAGIST_USERNAME&apiToken=$PACKAGIST_API_TOKEN" --header "content-type: application/json" --data '{"repository":{"url":"https://github.com/fiducia-cloud/fiducia-clients"}}'; }
