#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT/scripts/publish-common.sh"

tmp="$(mktemp -d)"
cleanup() {
  rm -r "$tmp"
}
trap cleanup EXIT HUP INT TERM

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
grep -Fq 'required publication file is missing: MISSING' "$tmp/missing.err"

ln -s README.md "$tmp/README.link"
if (
  cd "$tmp"
  publish_require_files README.link
) 2>"$tmp/symlink.err"; then
  printf 'expected symlink validation to fail\n' >&2
  exit 1
fi
grep -Fq 'required publication file must not be a symlink: README.link' "$tmp/symlink.err"

if publish_require_files 2>"$tmp/zero.err"; then
  printf 'expected zero-argument validation to fail\n' >&2
  exit 1
fi
grep -Fq 'publish_require_files requires at least one path' "$tmp/zero.err"

publish_parse_mode
[ "$PUBLISH_MODE" = dry-run ]
publish_parse_mode --dry-run
[ "$PUBLISH_MODE" = dry-run ]
publish_parse_mode --release
[ "$PUBLISH_MODE" = release ]

if (publish_parse_mode --publish) 2>"$tmp/publish.err"; then
  printf 'expected obsolete --publish mode to fail\n' >&2
  exit 1
fi
grep -Fq 'usage:' "$tmp/publish.err"

if (publish_parse_mode --dry-run --release) 2>"$tmp/many.err"; then
  printf 'expected multiple mode arguments to fail\n' >&2
  exit 1
fi
grep -Fq 'usage:' "$tmp/many.err"

# The parsed value and the Dart dispatch must use one canonical vocabulary.
grep -Fq '[ "$PUBLISH_MODE" = "release" ]' "$ROOT/clients/dart/publish.sh"
if grep -Fq '[ "$PUBLISH_MODE" = "publish" ]' "$ROOT/clients/dart/publish.sh"; then
  printf 'Dart publish dispatch still accepts the obsolete internal mode\n' >&2
  exit 1
fi

# Temporary publication output is not a repository projection. Streaming avoids
# passing an external absolute path into the generator's output/evidence logic.
grep -Fq 'generate_dart.py" --stdout > "$candidate"' "$ROOT/clients/dart/prepublish.sh"
if grep -Fq 'generate_dart.py" --output "$candidate"' "$ROOT/clients/dart/prepublish.sh"; then
  printf 'prepublish still passes a temporary path as a repository output\n' >&2
  exit 1
fi

printf 'publish contract regression tests passed\n'
