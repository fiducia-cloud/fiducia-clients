#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

client="${1:-}"
case "$client" in
  --*) client="" ;;
  "") ;;
  *) shift ;;
esac

if [ -z "$client" ]; then
  if [ "$(basename "$(dirname "$(pwd)")")" = "clients" ]; then
    client="$(basename "$(pwd)")"
  else
    printf 'usage: %s <client> [--dry-run|--release]\n' "$0" >&2
    exit 2
  fi
fi

release=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      release=0
      ;;
    --release)
      release=1
      ;;
    *)
      printf 'usage: %s <client> [--dry-run|--release]\n' "$0" >&2
      exit 2
      ;;
  esac
  shift
done

CLIENT_DIR="$ROOT_DIR/clients/$client"
if [ ! -d "$CLIENT_DIR" ]; then
  printf 'unknown fiducia client: %s\n' "$client" >&2
  exit 2
fi

run() {
  command="$1"
  if [ "$release" -eq 1 ]; then
    printf 'publishing %s: %s\n' "$client" "$command"
    (cd "$CLIENT_DIR" && sh -eu -c "$command")
  else
    printf '[dry-run] %s: %s\n' "$client" "$command"
  fi
}

run_root() {
  command="$1"
  if [ "$release" -eq 1 ]; then
    printf 'publishing %s: %s\n' "$client" "$command"
    (cd "$ROOT_DIR" && sh -eu -c "$command")
  else
    printf '[dry-run] %s: %s\n' "$client" "$command"
  fi
}

case "$client" in
  ts)
    run 'npm pack --dry-run && npm publish --access public'
    ;;
  python)
    run 'tmp="$(mktemp -d "${TMPDIR:-/tmp}/fiducia-client-python.XXXXXX")"; ${PYTHON:-python3} -m build --outdir "$tmp"; twine check "$tmp"/*; twine upload "$tmp"/*'
    ;;
  java)
    case "${FIDUCIA_MAVEN_TARGET:-both}" in
      central)
        run 'mvn -P release deploy'
        ;;
      artifactory)
        run ': "${ARTIFACTORY_URL:?set ARTIFACTORY_URL}"; mvn -P artifactory deploy'
        ;;
      both)
        run ': "${ARTIFACTORY_URL:?set ARTIFACTORY_URL}"; mvn -P release deploy && mvn -P artifactory deploy'
        ;;
      *)
        printf 'FIDUCIA_MAVEN_TARGET must be central, artifactory, or both\n' >&2
        exit 2
        ;;
    esac
    ;;
  ruby)
    run 'gem_file="$(gem build fiducia-client.gemspec | awk "/File:/ { print \$2 }")"; test -n "$gem_file"; gem push "$gem_file"'
    ;;
  go)
    run_root ': "${PACKAGE_VERSION:?set PACKAGE_VERSION}"; test -z "$(git status --porcelain)"; git tag "clients/go/v${PACKAGE_VERSION}"; git push origin "clients/go/v${PACKAGE_VERSION}"'
    ;;
  rust)
    run 'cargo package && cargo publish'
    ;;
  csharp)
    run 'tmp="$(mktemp -d "${TMPDIR:-/tmp}/fiducia-client-nuget.XXXXXX")"; dotnet pack -c Release --output "$tmp"; dotnet nuget push "$tmp"/*.nupkg --source https://api.nuget.org/v3/index.json --api-key "${NUGET_API_KEY:?set NUGET_API_KEY}"'
    ;;
  php)
    if [ "$release" -eq 1 ] && [ -n "${PACKAGIST_USERNAME:-}" ] && [ -n "${PACKAGIST_API_TOKEN:-}" ]; then
      run 'composer validate --strict && composer archive && curl --fail --request POST "https://packagist.org/api/update-package?username=${PACKAGIST_USERNAME}&apiToken=${PACKAGIST_API_TOKEN}" --header "content-type: application/json" --data "{\"repository\":{\"url\":\"https://github.com/fiducia-cloud/fiducia-clients\"}}"'
    else
      run 'composer validate --strict && composer archive'
    fi
    ;;
  powershell)
    run ': "${POWERSHELL_GALLERY_API_KEY:?set POWERSHELL_GALLERY_API_KEY}"; pwsh -NoLogo -NoProfile -Command "Test-ModuleManifest ./Fiducia.psd1 | Out-Null; Publish-Module -Path . -Repository PSGallery -NuGetApiKey \"${POWERSHELL_GALLERY_API_KEY}\""'
    ;;
  dart)
    run 'tmp="$(mktemp -d "${TMPDIR:-/tmp}/fiducia-client-dart.XXXXXX")"; mkdir -p "$tmp/lib"; cp fiducia.dart "$tmp/lib/fiducia_client.dart"; cp pubspec.yaml LICENSE README.md CHANGELOG.md "$tmp/"; cd "$tmp"; dart pub publish --dry-run && dart pub publish --force'
    ;;
  elixir)
    run 'mix hex.build && mix hex.publish'
    ;;
  shell)
    run_root ': "${PACKAGE_VERSION:?set PACKAGE_VERSION}"; test -z "$(git status --porcelain)"; git tag "clients/shell/v${PACKAGE_VERSION}"; git push origin "clients/shell/v${PACKAGE_VERSION}"; gh release create "clients/shell/v${PACKAGE_VERSION}" clients/shell/fiducia.sh --title "fiducia shell ${PACKAGE_VERSION}" --notes "Shell client release for fiducia.cloud."'
    ;;
  *)
    printf 'no publish command configured for client: %s\n' "$client" >&2
    exit 2
    ;;
esac
