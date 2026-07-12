#!/usr/bin/env sh
set -eu
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH= cd -- "$DIR/../.." && pwd)"
. "$ROOT/scripts/publish-common.sh"
publish_parse_mode "$@"
cd "$DIR"
cmake -S . -B "${TMPDIR:-/tmp}/fiducia-cpp-build"
if [ "$PUBLISH_MODE" = release ]; then
  publish_git_tag "$ROOT" cpp
  tag="clients/cpp/v$PACKAGE_VERSION"
  gh release create "$tag" fiducia.hpp --title "fiducia cpp $PACKAGE_VERSION" --notes "C++ client release for fiducia.cloud."
fi
