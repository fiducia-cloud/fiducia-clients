#!/usr/bin/env sh
# Pre-publish surface-contract guard.
#
# Drop this call at the top of clients/<lang>/publish.sh:
#
#     "$(git rev-parse --show-toplevel)/contract/bin/prepublish-guard.sh" "$(basename "$PWD")"
#
# In pre-publish mode warnings are errors: whatever is about to be uploaded to a
# package registry has to match the declared interface exactly, whatever tier the
# language sits at day to day.
set -eu

lang="${1:-$(basename "$PWD")}"

# Walk up to the repo root: the directory holding contract/surface.contract.json.
root="$(cd "$(dirname "$0")/../.." && pwd)"
while [ ! -f "$root/contract/surface.contract.json" ]; do
    parent="$(dirname "$root")"
    [ "$parent" = "$root" ] && { echo "prepublish-guard: no surface contract found above $PWD" >&2; exit 2; }
    root="$parent"
done

if ! command -v python3 >/dev/null 2>&1; then
    echo "prepublish-guard: python3 is required to verify the surface contract before publishing" >&2
    exit 2
fi

echo "prepublish-guard: verifying clients/$lang against the surface contract"
exec python3 "$root/contract/bin/check_surface.py" --prepublish --lang "$lang"
