#!/usr/bin/env sh
# Compatibility dispatcher. Publishing policy and commands live with each client.
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

client="${1:-}"
if [ -z "$client" ] || [ "${client#--}" != "$client" ]; then
  printf 'usage: %s <client> [--dry-run|--release]\n' "$0" >&2
  exit 2
fi
shift

publisher="$ROOT_DIR/clients/$client/publish.sh"
if [ ! -f "$publisher" ]; then
  printf 'no publisher configured for client: %s\n' "$client" >&2
  exit 2
fi

exec "$publisher" "$@"
