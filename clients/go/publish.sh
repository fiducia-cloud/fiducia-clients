#!/usr/bin/env sh
set -eu
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH= cd -- "$DIR/../.." && pwd)"
. "$ROOT/scripts/publish-common.sh"
publish_parse_mode "$@"
cd "$DIR"
go test ./...; go list -m
if [ "$PUBLISH_MODE" = release ]; then
  publish_git_tag "$ROOT" go
fi
