#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT/scripts/publish-common.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
: > "$tmp/README.md"
: > "$tmp/LICENSE"

(
  cd "$tmp"
  publish_require_files README.md LICENSE
)

if (
  cd "$tmp"
  publish_require_files README.md MISSING
) 2>"$tmp/missing.err"; then
  printf 'expected missing-file validation to fail\n' >&2
  exit 1
fi
grep -Fq 'required publish file is missing or unreadable: MISSING' "$tmp/missing.err"

if publish_require_files 2>"$tmp/zero.err"; then
  printf 'expected zero-argument validation to fail\n' >&2
  exit 1
fi
grep -Fq 'publish_require_files requires at least one path' "$tmp/zero.err"

publish_parse_mode --dry-run
[ "$PUBLISH_MODE" = dry-run ]
publish_parse_mode --release
[ "$PUBLISH_MODE" = release ]
if (publish_parse_mode --publish) 2>/dev/null; then
  printf 'expected non-canonical --publish mode to fail\n' >&2
  exit 1
fi

grep -Fq '[ "$PUBLISH_MODE" = "release" ]' "$ROOT/clients/dart/publish.sh"

printf 'publish contract regression tests passed\n'
