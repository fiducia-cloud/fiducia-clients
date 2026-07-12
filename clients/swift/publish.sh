#!/usr/bin/env sh
set -eu
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH= cd -- "$DIR/../.." && pwd)"
. "$ROOT/scripts/publish-common.sh"
publish_parse_mode "$@"
cd "$DIR"
swift build
if [ "$PUBLISH_MODE" = release ]; then
  publish_git_tag "$ROOT" swift
  tag="clients/swift/v$PACKAGE_VERSION"
  gh release create "$tag" Package.swift --title "fiducia swift $PACKAGE_VERSION" --notes "Swift client release for fiducia.cloud."
fi
