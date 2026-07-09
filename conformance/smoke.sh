#!/usr/bin/env bash
#
# smoke.sh — prove a running fiducia-node's /v1 API works end-to-end.
# A sanity gate for the client-conformance suite: it exercises the same
# request/response shapes the language clients assert on.
#
# Usage:  ./smoke.sh [BASE_URL]      (default http://localhost:8090)
# Requires: curl, jq.
set -euo pipefail

BASE="${1:-http://localhost:8090}"
command -v jq >/dev/null || { echo "smoke: jq is required" >&2; exit 1; }
fail() { echo "smoke: FAIL — $1" >&2; exit 1; }
eq()   { [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"; }

echo "smoke: target $BASE"

# 1) liveness / readiness
eq "$(curl -fsS "$BASE/healthz" | jq -r .status)" ok "GET /healthz .status"
curl -fsS "$BASE/readyz" >/dev/null || fail "GET /readyz not 2xx"

# 2) consensus status — single node must lead every shard
st="$(curl -fsS "$BASE/v1/status")"
lead="$(echo "$st" | jq -r '.consensus.leader_count')"
shards="$(echo "$st" | jq -r '.consensus.shard_count')"
eq "$lead" "$shards" "status: leader_count == shard_count (self-elected)"
echo "smoke: status OK — leads $lead/$shards shards, node_id=$(echo "$st" | jq -r .consensus.node_id)"

# 3) lock acquire (try-lock) -> release by fencing token
key="conf-smoke/lock-$$-$RANDOM"
acq="$(curl -fsS -XPOST "$BASE/v1/locks/acquire" -H 'content-type: application/json' \
  -d "{\"key\":\"$key\",\"holder\":\"smoke-a\",\"ttl_ms\":30000,\"wait\":false}")"
eq "$(echo "$acq" | jq -r '.committed')" true "lock acquire committed"
eq "$(echo "$acq" | jq -r '.result.output.acquired')" true "lock acquire acquired"
tok="$(echo "$acq" | jq -r '.result.output.fencing_token')"
[ "$tok" != null ] && [ -n "$tok" ] || fail "lock acquire missing fencing_token"
echo "smoke: lock acquired — fencing_token=$tok"
rel="$(curl -fsS -XPOST "$BASE/v1/locks/release" -H 'content-type: application/json' \
  -d "{\"holder\":\"smoke-a\",\"fencing_token\":$tok}")"
eq "$(echo "$rel" | jq -r '.result.output.released')" true "lock release released"

# 4) kv put -> get
kvkey="conf-smoke/flag-$$-$RANDOM"
put="$(curl -fsS -XPUT "$BASE/v1/kv?key=$kvkey" -H 'content-type: application/json' -d '{"value":"on"}')"
eq "$(echo "$put" | jq -r '.result.output.ok')" true "kv put ok"
got="$(curl -fsS "$BASE/v1/kv?key=$kvkey")"
eq "$(echo "$got" | jq -r '.found')" true "kv get found"
eq "$(echo "$got" | jq -r '.entry.value')" on "kv get value"

# 5) idempotency claim (first wins) + duplicate replay
idk="conf-smoke/idem-$$-$RANDOM"
c1="$(curl -fsS -XPOST "$BASE/v1/idempotency/claim" -H 'content-type: application/json' \
  -d "{\"key\":\"$idk\",\"owner\":\"smoke-a\",\"ttl_ms\":60000}")"
eq "$(echo "$c1" | jq -r '.result.output.claimed')" true "idempotency first claim claimed"
c2="$(curl -fsS -XPOST "$BASE/v1/idempotency/claim" -H 'content-type: application/json' \
  -d "{\"key\":\"$idk\",\"owner\":\"smoke-b\",\"ttl_ms\":60000}")"
eq "$(echo "$c2" | jq -r '.result.output.duplicate')" true "idempotency dup replay"
eq "$(echo "$c2" | jq -r '.result.output.record.owner')" smoke-a "idempotency dup keeps original owner"

echo "smoke: ALL PASS"
