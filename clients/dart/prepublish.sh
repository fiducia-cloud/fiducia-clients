#!/usr/bin/env sh
# Build and verify the complete Dart publication unit before release.
#
# The reviewed transport implementation remains clients/dart/fiducia.dart.
# Missing HTTP operations are derived from the independent operations.json
# contract by generate_dart.py into a temporary, exact publication candidate.
# Nothing generated is allowed to rewrite either authored contract authority.
set -eu

dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
root="$dir"
while [ ! -f "$root/contract/surface.contract.json" ]; do
    parent="$(dirname "$root")"
    [ "$parent" = "$root" ] && {
        echo "prepublish: no surface contract found above $dir" >&2
        exit 2
    }
    root="$parent"
done

if ! command -v python3 >/dev/null 2>&1; then
    echo "prepublish: python3 is required to generate the Dart publication unit" >&2
    exit 2
fi
if ! command -v dart >/dev/null 2>&1; then
    echo "prepublish: dart is required to format and analyze the publication unit" >&2
    exit 2
fi

destination="${1:-}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT HUP INT TERM
candidate="$work/fiducia_client.dart"
clients_root="$work/clients"
mkdir -p "$clients_root/dart"

python3 "$root/generate_dart.py" --output "$candidate"
dart format "$candidate"
dart format --output=none --set-exit-if-changed "$candidate"
dart analyze "$candidate"
cp "$candidate" "$clients_root/dart/fiducia_client.dart"
python3 "$root/contract/bin/check_surface.py" \
    --prepublish \
    --lang dart \
    --clients-root "$clients_root"

if [ -n "$destination" ]; then
    mkdir -p "$(dirname "$destination")"
    cp "$candidate" "$destination"
fi

printf '%s\n' "prepublish: generated, analyzed, and contract-checked the complete Dart client"
