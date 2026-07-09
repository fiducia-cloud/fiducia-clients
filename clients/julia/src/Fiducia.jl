# Fiducia HTTP client (Julia). HTTP.jl + JSON.jl. Implements PROTOCOL.md.
#
#   using Fiducia
#   c = Client("https://api.fiducia.cloud")
#   grant = lock_acquire(c, "orders/checkout"; ttl_ms = 30000)
#   out = grant["result"]["output"]
#   lock_release(c, "orders/checkout", "worker-a", out["fencing_token"])

module Fiducia

import HTTP
import JSON

export Client, FiduciaError
export health, status
export lock_get, lock_acquire, lock_acquire_many, try_lock, must_lock, lock_release
export semaphore_get, semaphore_acquire, try_semaphore, must_semaphore, semaphore, semaphore_release
export idempotency_get, idempotency_claim, idempotency_complete
export rw_acquire_read, rw_end_read, rw_acquire_write, rw_end_write
export kv_get, kv_put, kv_delete, kv_list
export rate_limit_get, rate_limit_check
export schedule_get, schedule_upsert, schedule_record_run, schedule_history
export election_get, election_campaign, election_renew, election_resign
export service_instances, service_register, service_heartbeat, service_deregister, service_list

"""
    FiduciaError(status, body)

Raised for any HTTP response with status >= 300. `status` is the numeric HTTP
status code and `body` is the parsed JSON body (or `nothing` when empty).
"""
struct FiduciaError <: Exception
    status::Int
    body
end

Base.showerror(io::IO, e::FiduciaError) = print(io, "FiduciaError: HTTP ", e.status)

"""
    Client(base_url)

A thin HTTP client for a fiducia endpoint. The trailing slash of `base_url` is
trimmed. Every operation takes the client as its first argument and returns the
parsed JSON response (a `Dict`/`Vector`/scalar, or `nothing` for an empty body).
"""
struct Client
    base_url::String

    Client(base_url::AbstractString) = new(String(rstrip(base_url, '/')))
end

# --- internals ---

# Percent-encode a value for use in a path segment or query value.
enc(s) = HTTP.escapeuri(string(s))

# Build a JSON body, omitting any pair whose value is `nothing` (CAS semantics:
# optional fields are only sent when the caller provides them).
function _body(pairs::Pair...)
    body = Dict{String,Any}()
    for (k, v) in pairs
        v === nothing || (body[k] = v)
    end
    return body
end

# Parse a response body. An empty body becomes `nothing`. A body that is not
# valid JSON (e.g. a proxy / load-balancer error page) falls back to the raw
# text, so a non-JSON error body surfaces as a `FiduciaError` carrying that text
# rather than crashing the client with a parse exception.
function _parse_body(text::AbstractString)
    isempty(strip(text)) && return nothing
    try
        return JSON.parse(text)
    catch
        return text
    end
end

function _request(c::Client, method::AbstractString, path::AbstractString, body = nothing)
    headers = Pair{String,String}[]
    payload = ""
    if body !== nothing
        push!(headers, "Content-Type" => "application/json")
        payload = JSON.json(body)
    end
    resp = HTTP.request(method, c.base_url * path, headers, payload; status_exception = false)
    text = String(resp.body)
    data = isempty(strip(text)) ? nothing : JSON.parse(text)
    resp.status >= 300 && throw(FiduciaError(resp.status, data))
    return data
end

# --- misc ---
health(c::Client) = _request(c, "GET", "/healthz")
status(c::Client) = _request(c, "GET", "/v1/status")

# --- locks ---
lock_get(c::Client, key) = _request(c, "GET", "/v1/locks?key=" * enc(key))

lock_acquire(c::Client, key; holder = nothing, ttl_ms = nothing, wait = true) =
    _request(c, "POST", "/v1/locks/acquire",
        _body("key" => key, "holder" => holder, "ttl_ms" => ttl_ms, "wait" => wait))

lock_acquire_many(c::Client, keys; holder = nothing, ttl_ms = nothing, wait = true) =
    _request(c, "POST", "/v1/locks/acquire",
        _body("keys" => keys, "holder" => holder, "ttl_ms" => ttl_ms, "wait" => wait))

try_lock(c::Client, key; holder = nothing, ttl_ms = nothing) =
    lock_acquire(c, key; holder = holder, ttl_ms = ttl_ms, wait = false)

must_lock(c::Client, key; holder = nothing, ttl_ms = nothing) =
    lock_acquire(c, key; holder = holder, ttl_ms = ttl_ms, wait = true)

# `lock` is the blocking alias of `must_lock`; provided as a method on
# `Base.lock` (Julia already exports `lock`) so `lock(c, key)` just works.
Base.lock(c::Client, key; holder = nothing, ttl_ms = nothing) =
    must_lock(c, key; holder = holder, ttl_ms = ttl_ms)

# `key` is accepted for symmetry with the other release calls but is not sent.
lock_release(c::Client, key, holder, fencing_token) =
    _request(c, "POST", "/v1/locks/release",
        _body("holder" => holder, "fencing_token" => fencing_token))

# --- semaphores ---
semaphore_get(c::Client, key) = _request(c, "GET", "/v1/semaphores?key=" * enc(key))

semaphore_acquire(c::Client, key, limit; holder = nothing, ttl_ms = nothing, wait = true) =
    _request(c, "POST", "/v1/semaphores/acquire",
        _body("key" => key, "holder" => holder, "ttl_ms" => ttl_ms, "limit" => limit, "wait" => wait))

try_semaphore(c::Client, key, limit; holder = nothing, ttl_ms = nothing) =
    semaphore_acquire(c, key, limit; holder = holder, ttl_ms = ttl_ms, wait = false)

must_semaphore(c::Client, key, limit; holder = nothing, ttl_ms = nothing) =
    semaphore_acquire(c, key, limit; holder = holder, ttl_ms = ttl_ms, wait = true)

semaphore(c::Client, key, limit; holder = nothing, ttl_ms = nothing) =
    must_semaphore(c, key, limit; holder = holder, ttl_ms = ttl_ms)

semaphore_release(c::Client, key, holder, fencing_token) =
    _request(c, "POST", "/v1/semaphores/release",
        _body("key" => key, "holder" => holder, "fencing_token" => fencing_token))

# --- idempotency ---
idempotency_get(c::Client, key) = _request(c, "GET", "/v1/idempotency?key=" * enc(key))

idempotency_claim(c::Client, key; owner = nothing, ttl_ms = nothing, ttl = nothing, metadata = nothing) =
    _request(c, "POST", "/v1/idempotency/claim",
        _body("key" => key, "owner" => owner, "ttl_ms" => ttl_ms, "ttl" => ttl, "metadata" => metadata))

idempotency_complete(c::Client, key, owner, fencing_token; result = nothing) =
    _request(c, "POST", "/v1/idempotency/complete",
        _body("key" => key, "owner" => owner, "fencing_token" => fencing_token, "result" => result))

# --- reader-writer locks ---
rw_acquire_read(c::Client, key; ttl_ms = nothing, wait = true) =
    _request(c, "POST", "/v1/rw/" * enc(key) * "/read", _body("ttl_ms" => ttl_ms, "wait" => wait))

rw_end_read(c::Client, key, lock_id) =
    _request(c, "POST", "/v1/rw/" * enc(key) * "/read/end", _body("lock_id" => lock_id))

rw_acquire_write(c::Client, key; ttl_ms = nothing, wait = true) =
    _request(c, "POST", "/v1/rw/" * enc(key) * "/write", _body("ttl_ms" => ttl_ms, "wait" => wait))

rw_end_write(c::Client, key, lock_id) =
    _request(c, "POST", "/v1/rw/" * enc(key) * "/write/end", _body("lock_id" => lock_id))

# --- config KV ---
kv_get(c::Client, key) = _request(c, "GET", "/v1/kv?key=" * enc(key))

kv_put(c::Client, key, value; ttl_ms = nothing, prev_revision = nothing) =
    _request(c, "PUT", "/v1/kv?key=" * enc(key),
        _body("value" => value, "ttl_ms" => ttl_ms, "prev_revision" => prev_revision))

kv_delete(c::Client, key) = _request(c, "DELETE", "/v1/kv?key=" * enc(key))

kv_list(c::Client, prefix) = _request(c, "GET", "/v1/kv?prefix=" * enc(prefix))

# --- rate limiting ---
rate_limit_get(c::Client, tenant, key) =
    _request(c, "GET", "/v1/rate-limit/" * enc(tenant) * "/" * enc(key))

rate_limit_check(c::Client, tenant, key, algorithm, limit, window_ms;
        refill_per_second = nothing, cost = nothing) =
    _request(c, "POST", "/v1/rate-limit/" * enc(tenant) * "/" * enc(key) * "/check",
        _body("algorithm" => algorithm, "limit" => limit, "window_ms" => window_ms,
            "refill_per_second" => refill_per_second, "cost" => cost))

# --- cron & scheduling ---
schedule_get(c::Client, name) = _request(c, "GET", "/v1/cron/schedules/" * enc(name))

schedule_upsert(c::Client, name, target; cron = nothing, one_shot_at_ms = nothing,
        delivery = nothing, max_retries = nothing) =
    _request(c, "PUT", "/v1/cron/schedules/" * enc(name),
        _body("target" => target, "cron" => cron, "one_shot_at_ms" => one_shot_at_ms,
            "delivery" => delivery, "max_retries" => max_retries))

schedule_record_run(c::Client, name, fire_id; fired_at_ms = nothing) =
    _request(c, "POST", "/v1/cron/schedules/" * enc(name) * "/runs",
        _body("fire_id" => fire_id, "fired_at_ms" => fired_at_ms))

schedule_history(c::Client, name) = _request(c, "GET", "/v1/cron/schedules/" * enc(name) * "/history")

# --- leader election ---
election_get(c::Client, name) = _request(c, "GET", "/v1/elections/" * enc(name))

election_campaign(c::Client, name, candidate, ttl_ms; metadata = nothing) =
    _request(c, "POST", "/v1/elections/" * enc(name) * "/campaign",
        _body("candidate" => candidate, "ttl_ms" => ttl_ms, "metadata" => metadata))

election_renew(c::Client, name, candidate, fencing_token) =
    _request(c, "POST", "/v1/elections/" * enc(name) * "/renew",
        _body("candidate" => candidate, "fencing_token" => fencing_token))

election_resign(c::Client, name, candidate, fencing_token) =
    _request(c, "POST", "/v1/elections/" * enc(name) * "/resign",
        _body("candidate" => candidate, "fencing_token" => fencing_token))

# --- service discovery ---
service_instances(c::Client, service) = _request(c, "GET", "/v1/services/" * enc(service))

service_register(c::Client, service, instance_id, address, ttl_ms; metadata = nothing) =
    _request(c, "PUT", "/v1/services/" * enc(service) * "/instances/" * enc(instance_id),
        _body("address" => address, "ttl_ms" => ttl_ms, "metadata" => metadata))

service_heartbeat(c::Client, service, instance_id; ttl_ms = nothing) =
    _request(c, "POST", "/v1/services/" * enc(service) * "/instances/" * enc(instance_id) * "/heartbeat",
        _body("ttl_ms" => ttl_ms))

service_deregister(c::Client, service, instance_id) =
    _request(c, "DELETE", "/v1/services/" * enc(service) * "/instances/" * enc(instance_id))

service_list(c::Client) = _request(c, "GET", "/v1/services")

end # module Fiducia
