#!/usr/bin/env sh
# Package/build/validate/release entrypoint for the MATLAB Fiducia client (see clients/PUBLISHING.md).
set -eu
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH= cd -- "$DIR/../.." && pwd)"
. "$ROOT/scripts/publish-common.sh"
publish_parse_mode "$@"
cd "$DIR"
test -f Fiducia.m; test -f README.md
if [ "$PUBLISH_MODE" = release ]; then
  publish_git_tag "$ROOT" matlab
  tag="clients/matlab/v$PACKAGE_VERSION"
  gh release create "$tag" Fiducia.m --title "fiducia matlab $PACKAGE_VERSION" --notes "MATLAB client release for fiducia.cloud."
fi
