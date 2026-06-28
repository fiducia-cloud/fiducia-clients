#!/usr/bin/env bash
# Fiducia HTTP client (shell). Requires `curl` and `jq`. Implements PROTOCOL.md.
#
#   source fiducia.sh
#   export FIDUCIA_URL=https://api.fiducia.cloud
#   fiducia_lock_acquire orders/checkout 30000
#   fiducia_kv_put flags/new-ui on 60000
#
# Every function prints the JSON response to stdout (pipe to `jq`).

: "${FIDUCIA_URL:=http://localhost:8088}"

_fiducia_req() { # method path [json-body]
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -fsS -X "$method" "$FIDUCIA_URL$path" -H 'content-type: application/json' -d "$body"
  else
    curl -fsS -X "$method" "$FIDUCIA_URL$path"
  fi
}

_fiducia_enc() { jq -rn --arg s "$1" '$s|@uri'; }

# --- misc ---
fiducia_health() { _fiducia_req GET /healthz; }
fiducia_status() { _fiducia_req GET /v1/status; }

# --- locks & semaphores ---
fiducia_lock_acquire() { # key [ttl_ms] [wait] [max]
  local key="$1" ttl="${2:-null}" wait="${3:-true}" max="${4:-1}"
  _fiducia_req POST "/v1/locks/$(_fiducia_enc "$key")/acquire" \
    "$(jq -nc --argjson t "$ttl" --argjson w "$wait" --argjson m "$max" '{ttl_ms:$t,wait:$w,max:$m}')"
}
fiducia_lock_release() { # key lock_id
  _fiducia_req POST "/v1/locks/$(_fiducia_enc "$1")/release" "$(jq -nc --arg l "$2" '{lock_id:$l}')"
}

# --- reader-writer locks ---
fiducia_rw_acquire_read()  { _fiducia_req POST "/v1/rw/$(_fiducia_enc "$1")/read"      "$(jq -nc --argjson t "${2:-null}" --argjson w "${3:-true}" '{ttl_ms:$t,wait:$w}')"; }
fiducia_rw_end_read()      { _fiducia_req POST "/v1/rw/$(_fiducia_enc "$1")/read/end"  "$(jq -nc --arg l "$2" '{lock_id:$l}')"; }
fiducia_rw_acquire_write() { _fiducia_req POST "/v1/rw/$(_fiducia_enc "$1")/write"     "$(jq -nc --argjson t "${2:-null}" --argjson w "${3:-true}" '{ttl_ms:$t,wait:$w}')"; }
fiducia_rw_end_write()     { _fiducia_req POST "/v1/rw/$(_fiducia_enc "$1")/write/end" "$(jq -nc --arg l "$2" '{lock_id:$l}')"; }

# --- config KV ---
fiducia_kv_get()    { _fiducia_req GET    "/v1/kv?key=$(_fiducia_enc "$1")"; }
fiducia_kv_put()    { _fiducia_req PUT    "/v1/kv?key=$(_fiducia_enc "$1")" "$(jq -nc --arg v "$2" --argjson t "${3:-null}" '{value:$v,ttl_ms:$t}')"; }
fiducia_kv_delete() { _fiducia_req DELETE "/v1/kv?key=$(_fiducia_enc "$1")"; }
fiducia_kv_list()   { _fiducia_req GET    "/v1/kv?prefix=$(_fiducia_enc "$1")"; }

# --- leader election ---
fiducia_election_campaign() { _fiducia_req POST "/v1/elections/$(_fiducia_enc "$1")/campaign" "$(jq -nc --arg c "$2" --argjson t "$3" '{candidate:$c,ttl_ms:$t}')"; }
fiducia_election_renew()    { _fiducia_req POST "/v1/elections/$(_fiducia_enc "$1")/renew"    "$(jq -nc --arg c "$2" --argjson f "$3" '{candidate:$c,fencing_token:$f}')"; }
fiducia_election_resign()   { _fiducia_req POST "/v1/elections/$(_fiducia_enc "$1")/resign"   "$(jq -nc --arg c "$2" --argjson f "$3" '{candidate:$c,fencing_token:$f}')"; }
fiducia_election_get()      { _fiducia_req GET  "/v1/elections/$(_fiducia_enc "$1")"; }

# --- service discovery ---
fiducia_service_register()   { _fiducia_req PUT    "/v1/services/$(_fiducia_enc "$1")/instances/$(_fiducia_enc "$2")" "$(jq -nc --arg a "$3" --argjson t "$4" '{address:$a,ttl_ms:$t}')"; }
fiducia_service_heartbeat()  { _fiducia_req POST   "/v1/services/$(_fiducia_enc "$1")/instances/$(_fiducia_enc "$2")/heartbeat"; }
fiducia_service_deregister() { _fiducia_req DELETE "/v1/services/$(_fiducia_enc "$1")/instances/$(_fiducia_enc "$2")"; }
fiducia_service_instances()  { _fiducia_req GET    "/v1/services/$(_fiducia_enc "$1")"; }
fiducia_service_list()       { _fiducia_req GET    "/v1/services"; }
