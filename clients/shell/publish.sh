#!/usr/bin/env sh
set -eu
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH= cd -- "$DIR/../.." && pwd)"
. "$ROOT/scripts/publish-common.sh"
publish_parse_mode "$@"
cd "$DIR"
sh -n fiducia.sh
if [ "$PUBLISH_MODE" = release ]; then
  publish_git_tag "$ROOT" shell
  tag="clients/shell/v$PACKAGE_VERSION"
  gh release create "$tag" fiducia.sh --title "fiducia shell $PACKAGE_VERSION" --notes "Shell client release for fiducia.cloud."
fi
