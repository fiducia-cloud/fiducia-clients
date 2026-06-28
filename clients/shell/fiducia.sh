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
_fiducia_now_ms() { jq -n 'now*1000|floor'; }
_fiducia_gen_holder() {
  printf 'fdc-%s' "$( (uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$RANDOM$RANDOM$RANDOM") | tr 'A-Z' 'a-z' | tr -d '-' )"
}

# --- misc ---
fiducia_health() { _fiducia_req GET /healthz; }
fiducia_status() { _fiducia_req GET /v1/status; }

# --- locks (current protocol: holder + fencing_token, keys in the body) ---
fiducia_lock_get() { _fiducia_req GET "/v1/locks?key=$(_fiducia_enc "$1")"; }
fiducia_lock_acquire() { # key holder [ttl_ms] [wait]
  local key="$1" holder="$2" ttl="${3:-null}" wait="${4:-false}"
  _fiducia_req POST "/v1/locks/acquire" \
    "$(jq -nc --arg k "$key" --arg h "$holder" --argjson t "$ttl" --argjson w "$wait" '{keys:[$k],holder:$h,ttl_ms:$t,wait:$w}')"
}
fiducia_lock_release() { # holder fencing_token
  _fiducia_req POST "/v1/locks/release" "$(jq -nc --arg h "$1" --argjson f "$2" '{holder:$h,fencing_token:$f}')"
}

# --- semaphores ---
fiducia_semaphore_get() { _fiducia_req GET "/v1/semaphores?key=$(_fiducia_enc "$1")"; }
fiducia_semaphore_acquire() { # key limit holder [ttl_ms] [wait]
  local key="$1" limit="$2" holder="$3" ttl="${4:-null}" wait="${5:-false}"
  _fiducia_req POST "/v1/semaphores/acquire" \
    "$(jq -nc --arg k "$key" --argjson l "$limit" --arg h "$holder" --argjson t "$ttl" --argjson w "$wait" '{key:$k,limit:$l,holder:$h,ttl_ms:$t,wait:$w}')"
}
fiducia_semaphore_release() { # key holder fencing_token
  _fiducia_req POST "/v1/semaphores/release" "$(jq -nc --arg k "$1" --arg h "$2" --argjson f "$3" '{key:$k,holder:$h,fencing_token:$f}')"
}

# --- high-level blocking / try acquisition (live-mutex style) ---
#
# On success these print a handle JSON ({holder,fencing_token,key}) to stdout and
# return 0; on "held / at capacity" (try) or timeout (blocking) they return 1.
# Release with: handle=$(fiducia_lock key ...); fiducia_release "$handle"
fiducia_try_lock() { # key [ttl_ms] [holder]
  local key="$1" ttl="${2:-60000}" holder="${3:-$(_fiducia_gen_holder)}"
  local out; out="$(fiducia_lock_acquire "$key" "$holder" "$ttl" false | jq -c '.result.output')" || return 2
  if [ "$(printf '%s' "$out" | jq -r '.acquired')" = "true" ]; then
    jq -nc --arg h "$holder" --argjson f "$(printf '%s' "$out" | jq '.fencing_token')" --arg k "$key" '{holder:$h,fencing_token:$f,key:$k}'
    return 0
  fi
  return 1
}

fiducia_lock() { # key [ttl_ms] [max_wait_ms] [retry_ms] [holder]
  local key="$1" ttl="${2:-60000}" maxwait="${3:-30000}" retry="${4:-250}" holder="${5:-$(_fiducia_gen_holder)}"
  local out; out="$(fiducia_lock_acquire "$key" "$holder" "$ttl" true | jq -c '.result.output')" || return 2
  if [ "$(printf '%s' "$out" | jq -r '.acquired')" = "true" ]; then
    jq -nc --arg h "$holder" --argjson f "$(printf '%s' "$out" | jq '.fencing_token')" --arg k "$key" '{holder:$h,fencing_token:$f,key:$k}'
    return 0
  fi
  local deadline; deadline=$(( $(_fiducia_now_ms) + maxwait ))
  while [ "$(_fiducia_now_ms)" -lt "$deadline" ]; do
    sleep "$(jq -n --argjson r "$retry" '$r/1000')"
    local lk; lk="$(fiducia_lock_get "$key" | jq -c '.lock // empty')" || continue
    if [ -n "$lk" ] && [ "$(printf '%s' "$lk" | jq -r '.holder // empty')" = "$holder" ] && [ "$(printf '%s' "$lk" | jq -r '.fencing_token // empty')" != "" ]; then
      jq -nc --arg h "$holder" --argjson f "$(printf '%s' "$lk" | jq '.fencing_token')" --arg k "$key" '{holder:$h,fencing_token:$f,key:$k}'
      return 0
    fi
  done
  return 1
}

# mustLock is wait:true — same as fiducia_lock.
fiducia_must_lock() { fiducia_lock "$@"; }

fiducia_try_semaphore() { # key limit [ttl_ms] [holder]
  local key="$1" limit="$2" ttl="${3:-60000}" holder="${4:-$(_fiducia_gen_holder)}"
  local out; out="$(fiducia_semaphore_acquire "$key" "$limit" "$holder" "$ttl" false | jq -c '.result.output')" || return 2
  if [ "$(printf '%s' "$out" | jq -r '.acquired')" = "true" ]; then
    jq -nc --arg h "$holder" --argjson f "$(printf '%s' "$out" | jq '.fencing_token')" --arg k "$key" '{holder:$h,fencing_token:$f,key:$k}'
    return 0
  fi
  return 1
}

fiducia_acquire_semaphore() { # key limit [ttl_ms] [max_wait_ms] [retry_ms] [holder]
  local key="$1" limit="$2" ttl="${3:-60000}" maxwait="${4:-30000}" retry="${5:-250}" holder="${6:-$(_fiducia_gen_holder)}"
  local out; out="$(fiducia_semaphore_acquire "$key" "$limit" "$holder" "$ttl" true | jq -c '.result.output')" || return 2
  if [ "$(printf '%s' "$out" | jq -r '.acquired')" = "true" ]; then
    jq -nc --arg h "$holder" --argjson f "$(printf '%s' "$out" | jq '.fencing_token')" --arg k "$key" '{holder:$h,fencing_token:$f,key:$k}'
    return 0
  fi
  local deadline; deadline=$(( $(_fiducia_now_ms) + maxwait ))
  while [ "$(_fiducia_now_ms)" -lt "$deadline" ]; do
    sleep "$(jq -n --argjson r "$retry" '$r/1000')"
    local slot; slot="$(fiducia_semaphore_get "$key" | jq -c --arg h "$holder" '.semaphore.holders[]? | select(.holder==$h)' | head -n1)" || continue
    if [ -n "$slot" ] && [ "$(printf '%s' "$slot" | jq -r '.fencing_token // empty')" != "" ]; then
      jq -nc --arg h "$holder" --argjson f "$(printf '%s' "$slot" | jq '.fencing_token')" --arg k "$key" '{holder:$h,fencing_token:$f,key:$k}'
      return 0
    fi
  done
  return 1
}

# Release a handle printed by the high-level lock/semaphore helpers.
fiducia_release() { # handle-json
  local h; h="$1"
  fiducia_lock_release "$(printf '%s' "$h" | jq -r '.holder')" "$(printf '%s' "$h" | jq '.fencing_token')"
}
fiducia_release_semaphore() { # handle-json
  local h; h="$1"
  fiducia_semaphore_release "$(printf '%s' "$h" | jq -r '.key')" "$(printf '%s' "$h" | jq -r '.holder')" "$(printf '%s' "$h" | jq '.fencing_token')"
}

# --- reader-writer locks ---
fiducia_rw_acquire_read()  { _fiducia_req POST "/v1/rw/$(_fiducia_enc "$1")/read"      "$(jq -nc --argjson t "${2:-null}" --argjson w "${3:-true}" '{ttl_ms:$t,wait:$w}')"; }
fiducia_rw_end_read()      { _fiducia_req POST "/v1/rw/$(_fiducia_enc "$1")/read/end"  "$(jq -nc --arg l "$2" '{lock_id:$l}')"; }
fiducia_rw_acquire_write() { _fiducia_req POST "/v1/rw/$(_fiducia_enc "$1")/write"     "$(jq -nc --argjson t "${2:-null}" --argjson w "${3:-true}" '{ttl_ms:$t,wait:$w}')"; }
fiducia_rw_end_write()     { _fiducia_req POST "/v1/rw/$(_fiducia_enc "$1")/write/end" "$(jq -nc --arg l "$2" '{lock_id:$l}')"; }

# --- config KV ---
fiducia_kv_get()    { _fiducia_req GET    "/v1/kv/$(_fiducia_enc "$1")"; }
fiducia_kv_put()    { _fiducia_req PUT    "/v1/kv/$(_fiducia_enc "$1")" "$(jq -nc --arg v "$2" --argjson t "${3:-null}" '{value:$v,ttl_ms:$t}')"; }
fiducia_kv_delete() { _fiducia_req DELETE "/v1/kv/$(_fiducia_enc "$1")"; }
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
