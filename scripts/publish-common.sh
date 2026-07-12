#!/usr/bin/env sh
# Generic release plumbing. Ecosystem-specific commands belong in
# clients/<language>/publish.sh.

set -eu

publish_parse_mode() {
  PUBLISH_MODE=dry-run
  if [ "$#" -gt 1 ]; then
    printf 'usage: %s [--dry-run|--release]\n' "$0" >&2
    exit 2
  fi
  if [ "$#" -eq 1 ]; then
    case "$1" in
      --dry-run) PUBLISH_MODE=dry-run ;;
      --release) PUBLISH_MODE=release ;;
      *)
        printf 'usage: %s [--dry-run|--release]\n' "$0" >&2
        exit 2
        ;;
    esac
  fi
  export PUBLISH_MODE
}

publish_require() {
  name="$1"
  eval "value=\${$name:-}"
  if [ -z "$value" ]; then
    printf '%s must be set\n' "$name" >&2
    exit 2
  fi
}

publish_require_clean_tree() {
  root="$1"
  if [ -n "$(git -C "$root" status --porcelain)" ]; then
    printf 'release requires a clean git worktree\n' >&2
    exit 1
  fi
}

publish_require_version() {
  publish_require PACKAGE_VERSION
  case "$PACKAGE_VERSION" in
    v*|*/*|*' '*)
      printf 'PACKAGE_VERSION must be a bare version without v, slash, or spaces\n' >&2
      exit 2
      ;;
  esac
}

publish_git_tag() {
  root="$1"
  client="$2"
  publish_require_version
  publish_require_clean_tree "$root"
  tag="clients/$client/v$PACKAGE_VERSION"
  if git -C "$root" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    printf 'tag already exists: %s\n' "$tag" >&2
    exit 1
  fi
  git -C "$root" tag "$tag"
  git -C "$root" push origin "$tag"
}

# publish_check_version FILE PATTERN
# Guard against version drift: the version embedded in a client's own package
# manifest must match the release version the operator asked for. PATTERN is an
# extended-regex selecting the manifest's version line; the first dotted version
# on that line is compared against PACKAGE_VERSION.
#
# No-op when PACKAGE_VERSION is unset, so registry publishes (where the manifest
# is the single source of truth) keep working without it; a unified release that
# does set PACKAGE_VERSION gets the drift guard for free.
publish_check_version() {
  file="$1"
  pattern="$2"
  [ -n "${PACKAGE_VERSION:-}" ] || return 0
  if [ ! -f "$file" ]; then
    printf 'cannot check version: manifest not found: %s\n' "$file" >&2
    exit 2
  fi
  line="$(grep -Em1 "$pattern" "$file" || true)"
  found="$(printf '%s\n' "$line" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z]+)*' | head -n1 || true)"
  if [ -z "$found" ]; then
    printf 'cannot find a version in %s (pattern: %s)\n' "$file" "$pattern" >&2
    exit 2
  fi
  if [ "$found" != "$PACKAGE_VERSION" ]; then
    printf 'version drift: %s declares %s but PACKAGE_VERSION is %s\n' \
      "$file" "$found" "$PACKAGE_VERSION" >&2
    exit 1
  fi
}
