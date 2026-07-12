#!/usr/bin/env sh
set -eu
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH= cd -- "$DIR/../.." && pwd)"
. "$ROOT/scripts/publish-common.sh"
publish_parse_mode "$@"
cd "$DIR"
publish_check_version build.zig.zon '\.version'
zig build
if [ "$PUBLISH_MODE" = release ]; then
  publish_git_tag "$ROOT" zig
  tag="clients/zig/v$PACKAGE_VERSION"
  gh release create "$tag" build.zig.zon build.zig --title "fiducia zig $PACKAGE_VERSION" --notes "Zig client release for fiducia.cloud."
fi
