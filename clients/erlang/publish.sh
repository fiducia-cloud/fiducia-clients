#!/usr/bin/env sh
# Package/build/validate/release entrypoint for the Erlang Fiducia client (see clients/PUBLISHING.md).
set -eu
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/../../scripts/publish-common.sh"
publish_parse_mode "$@"
cd "$DIR"
publish_check_version src/fiducia_client.app.src 'vsn'
rebar3 hex build
[ "$PUBLISH_MODE" = dry-run ] || { rebar3 hex publish --yes; }
