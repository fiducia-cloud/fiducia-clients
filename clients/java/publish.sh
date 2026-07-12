#!/usr/bin/env sh
set -eu
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/../../scripts/publish-common.sh"
publish_parse_mode "$@"
cd "$DIR"
mvn -P release verify
[ "$PUBLISH_MODE" = dry-run ] || { case "${FIDUCIA_MAVEN_TARGET:-central}" in central) mvn -P release deploy;; artifactory) publish_require ARTIFACTORY_URL; mvn -P artifactory deploy;; both) publish_require ARTIFACTORY_URL; mvn -P release deploy; mvn -P artifactory deploy;; *) echo "invalid FIDUCIA_MAVEN_TARGET" >&2; exit 2;; esac; }
