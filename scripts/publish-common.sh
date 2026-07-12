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
