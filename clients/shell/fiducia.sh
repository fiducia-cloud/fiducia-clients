#!/usr/bin/env bash
# Fiducia HTTP client (shell). Requires `curl` and `jq`. Implements PROTOCOL.md.
#
#   source fiducia.sh
#   export FIDUCIA_URL=https://api.fiducia.cloud
#   handle=$(fiducia_lock orders/checkout) && fiducia_release "$handle"   # blocks
#   handle=$(fiducia_try_lock orders/checkout) && fiducia_release "$handle" # non-blocking
#   fiducia_kv_put flags/new-ui on 60000
#
# Every function prints the JSON response to stdout (pipe to `jq`).

: "${FIDUCIA_URL:=http://localhost:8088}"

_fiducia_req() { # method path [json-body] [max_retries] [timeout_seconds] [retry_delay_seconds]
  local method="$1" path="$2" body="${3:-}" max_retries="${4:-${FIDUCIA_MAX_RETRIES:-0}}"
  local timeout="${5:-${FIDUCIA_TIMEOUT:-}}" retry_delay="${6:-${FIDUCIA_RETRY_DELAY:-0}}" attempt=0
  while true; do
    local args=(-fsS -X "$method")
    if [ -n "$timeout" ]; then args+=(--max-time "$timeout"); fi
    if [ -n "$body" ]; then
      args+=("$FIDUCIA_URL$path" -H 'content-type: application/json' -d "$body")
    else
      args+=("$FIDUCIA_URL$path")
    fi
    if curl "${args[@]}"; then return 0; fi
    local curl_status=$?
    if [ "$curl_status" -eq 22 ]; then return "$curl_status"; fi
    if [ "$attempt" -ge "$max_retries" ]; then return "$curl_status"; fi
    attempt=$((attempt + 1))
    if [ "$retry_delay" != "0" ]; then sleep "$retry_delay"; fi
  done
}

_fiducia_enc() { jq -rn --arg s "$1" '$s|@uri'; }
_fiducia_now_ms() { jq -n 'now*1000|floor'; }
_fiducia_gen_holder() {
  printf 'fdc-%s' "$( (uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$RANDOM$RANDOM$RANDOM") | tr 'A-Z' 'a-z' | tr -d '-' )"
}

# --- misc ---
fiducia_health() { _fiducia_req GET /healthz; }
fiducia_status() { _fiducia_req GET /v1/status; }

# --- locks & semaphores ---
fiducia_lock_acquire() { # key [ttl_ms] [wait] [max] [max_retries] [timeout_seconds] [retry_delay_seconds]
  local key="$1" ttl="${2:-null}" wait="${3:-true}" max="${4:-1}"
  _fiducia_req POST "/v1/locks/acquire" \
    "$(jq -nc --arg k "$key" --argjson t "$ttl" --argjson w "$wait" --argjson m "$max" '{key:$k,ttl_ms:$t,wait:$w,max:$m}')" \
    "${5:-${FIDUCIA_MAX_RETRIES:-0}}" "${6:-${FIDUCIA_LOCK_TIMEOUT:-${FIDUCIA_TIMEOUT:-}}}" "${7:-${FIDUCIA_RETRY_DELAY:-0}}"
}
fiducia_try_lock() { fiducia_lock_acquire "$1" "${2:-null}" false "${3:-1}" "${4:-${FIDUCIA_MAX_RETRIES:-0}}" "${5:-${FIDUCIA_LOCK_TIMEOUT:-${FIDUCIA_TIMEOUT:-}}}" "${6:-${FIDUCIA_RETRY_DELAY:-0}}"; }
fiducia_must_lock() { fiducia_lock_acquire "$1" "${2:-null}" true "${3:-1}" "${4:-${FIDUCIA_MAX_RETRIES:-0}}" "${5:-${FIDUCIA_LOCK_TIMEOUT:-${FIDUCIA_TIMEOUT:-}}}" "${6:-${FIDUCIA_RETRY_DELAY:-0}}"; }
fiducia_lock() { fiducia_must_lock "$@"; }
fiducia_lock_release() { # key holder fencing_token
  _fiducia_req POST "/v1/locks/release" "$(jq -nc --arg h "$2" --argjson f "$3" '{holder:$h,fencing_token:$f}')"
}
fiducia_semaphore_acquire() { # key [ttl_ms] [wait] [max] [max_retries] [timeout_seconds] [retry_delay_seconds]
  local key="$1" ttl="${2:-null}" wait="${3:-true}" max="${4:-2}"
  _fiducia_req POST "/v1/semaphores/acquire" \
    "$(jq -nc --arg k "$key" --argjson t "$ttl" --argjson w "$wait" --argjson m "$max" '{key:$k,ttl_ms:$t,wait:$w,limit:$m}')" \
    "${5:-${FIDUCIA_MAX_RETRIES:-0}}" "${6:-${FIDUCIA_LOCK_TIMEOUT:-${FIDUCIA_TIMEOUT:-}}}" "${7:-${FIDUCIA_RETRY_DELAY:-0}}"
}
fiducia_try_semaphore() { fiducia_semaphore_acquire "$1" "${2:-null}" false "${3:-2}" "${4:-${FIDUCIA_MAX_RETRIES:-0}}" "${5:-${FIDUCIA_LOCK_TIMEOUT:-${FIDUCIA_TIMEOUT:-}}}" "${6:-${FIDUCIA_RETRY_DELAY:-0}}"; }
fiducia_must_semaphore() { fiducia_semaphore_acquire "$1" "${2:-null}" true "${3:-2}" "${4:-${FIDUCIA_MAX_RETRIES:-0}}" "${5:-${FIDUCIA_LOCK_TIMEOUT:-${FIDUCIA_TIMEOUT:-}}}" "${6:-${FIDUCIA_RETRY_DELAY:-0}}"; }
fiducia_semaphore() { fiducia_must_semaphore "$@"; }
fiducia_semaphore_release() { # key holder fencing_token
  _fiducia_req POST "/v1/semaphores/release" "$(jq -nc --arg k "$1" --arg h "$2" --argjson f "$3" '{key:$k,holder:$h,fencing_token:$f}')"
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
