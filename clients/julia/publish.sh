#!/usr/bin/env sh
set -eu
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH= cd -- "$DIR/../.." && pwd)"
. "$ROOT/scripts/publish-common.sh"
publish_parse_mode "$@"
cd "$DIR"
publish_check_version Project.toml '^version'
julia --startup-file=no -e 'using TOML; TOML.parsefile("Project.toml")'
if [ "$PUBLISH_MODE" = release ]; then
  publish_git_tag "$ROOT" julia
  tag="clients/julia/v$PACKAGE_VERSION"
  gh release create "$tag" Project.toml --title "fiducia julia $PACKAGE_VERSION" --notes "Julia client release for fiducia.cloud."
fi
