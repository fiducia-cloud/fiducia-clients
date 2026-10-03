#!/usr/bin/env sh
# Package/build/validate/release entrypoint for the C Fiducia client (see clients/PUBLISHING.md).
set -eu
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH= cd -- "$DIR/../.." && pwd)"
. "$ROOT/scripts/publish-common.sh"
publish_parse_mode "$@"
cd "$DIR"
cmake -S . -B "${TMPDIR:-/tmp}/fiducia-c-build"
if [ "$PUBLISH_MODE" = release ]; then
  publish_git_tag "$ROOT" c
  tag="clients/c/v$PACKAGE_VERSION"
  gh release create "$tag" fiducia.h fiducia.c --title "fiducia c $PACKAGE_VERSION" --notes "C client release for fiducia.cloud."
fi
