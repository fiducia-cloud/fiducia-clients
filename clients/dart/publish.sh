#!/usr/bin/env sh
# Publish fiducia_client to pub.dev. Default mode is a dry run.
set -eu

DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH= cd -- "$DIR/../.." && pwd)"
. "$ROOT/scripts/publish-common.sh"

publish_parse_mode "$@"
cd "$DIR"
publish_check_version pubspec.yaml '^version:[[:space:]]*'
publish_require_files pubspec.yaml README.md LICENSE CHANGELOG.md

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/lib"
"$DIR/prepublish.sh" "$tmp/lib/fiducia_client.dart"
cp pubspec.yaml README.md LICENSE CHANGELOG.md "$tmp/"
cd "$tmp"

if [ "$PUBLISH_MODE" = "publish" ]; then
    dart pub publish
else
    dart pub publish --dry-run
fi
