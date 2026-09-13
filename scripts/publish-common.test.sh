#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT/scripts/publish-common.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

printf 'metadata\n' >"$tmp/README.md"
printf 'license\n' >"$tmp/LICENSE"

(
  cd "$tmp"
  publish_require_files README.md LICENSE
)

if (
  cd "$tmp"
  publish_require_files README.md MISSING.md
) >"$tmp/missing.out" 2>"$tmp/missing.err"; then
  printf 'missing publication file was accepted\n' >&2
  exit 1
fi
grep -F 'required publication file is missing: MISSING.md' "$tmp/missing.err" >/dev/null

ln -s README.md "$tmp/README-LINK.md"
if (
  cd "$tmp"
  publish_require_files README-LINK.md
) >"$tmp/symlink.out" 2>"$tmp/symlink.err"; then
  printf 'symlinked publication file was accepted\n' >&2
  exit 1
fi
grep -F 'required publication file must not be a symlink: README-LINK.md' "$tmp/symlink.err" >/dev/null

# The production helper intentionally exits the invoking shell on invalid input.
# Run the negative probe in a child shell so the harness can inspect its result.
if (
  publish_require_files
) >"$tmp/empty.out" 2>"$tmp/empty.err"; then
  printf 'empty publication file list was accepted\n' >&2
  exit 1
fi
grep -F 'publish_require_files requires at least one path' "$tmp/empty.err" >/dev/null

printf 'publish-common file guards passed\n'
