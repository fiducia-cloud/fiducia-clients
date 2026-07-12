#!/usr/bin/env sh
set -eu
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/../../scripts/publish-common.sh"
publish_parse_mode "$@"
cd "$DIR"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/fiducia-python.XXXXXX")"; ${PYTHON:-python3} -m build --outdir "$tmp"; twine check "$tmp"/*
[ "$PUBLISH_MODE" = dry-run ] || { twine upload "$tmp"/*; }
