#!/usr/bin/env sh
# Package/build/validate/release entrypoint for the Python Fiducia client (see clients/PUBLISHING.md).
set -eu
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/../../scripts/publish-common.sh"
publish_parse_mode "$@"
cd "$DIR"
publish_check_version pyproject.toml '^version'
tmp="$(mktemp -d "${TMPDIR:-/tmp}/fiducia-python.XXXXXX")"; ${PYTHON:-python3} -m build --outdir "$tmp"; twine check "$tmp"/*
[ "$PUBLISH_MODE" = dry-run ] || { twine upload --non-interactive "$tmp"/*; }
