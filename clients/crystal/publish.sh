#!/usr/bin/env sh
# Package/build/validate/release entrypoint for the Crystal Fiducia client (see clients/PUBLISHING.md).
set -eu
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH= cd -- "$DIR/../.." && pwd)"
. "$ROOT/scripts/publish-common.sh"
publish_parse_mode "$@"
cd "$DIR"
publish_check_version shard.yml '^version:'
crystal build --no-codegen src/fiducia.cr
if [ "$PUBLISH_MODE" = release ]; then
  publish_git_tag "$ROOT" crystal
  tag="clients/crystal/v$PACKAGE_VERSION"
  gh release create "$tag" shard.yml --title "fiducia crystal $PACKAGE_VERSION" --notes "Crystal client release for fiducia.cloud."
fi
