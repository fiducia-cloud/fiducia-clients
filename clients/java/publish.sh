#!/usr/bin/env sh
# Package/build/validate/release entrypoint for the Java Fiducia client (see clients/PUBLISHING.md).
set -eu
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$DIR/../../scripts/publish-common.sh"
publish_parse_mode "$@"
cd "$DIR"
publish_check_version pom.xml '^  <version>'
mvn -B -P release verify
[ "$PUBLISH_MODE" = dry-run ] || { case "${FIDUCIA_MAVEN_TARGET:-central}" in central) mvn -B -P release deploy;; artifactory) publish_require ARTIFACTORY_URL; mvn -B -P artifactory deploy;; both) publish_require ARTIFACTORY_URL; mvn -B -P release deploy; mvn -B -P artifactory deploy;; *) echo "invalid FIDUCIA_MAVEN_TARGET" >&2; exit 2;; esac; }
