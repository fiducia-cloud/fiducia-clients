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

export Client, FiduciaError, LockTimeout
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
    LockTimeout(keys, waited_ms)

Thrown by the blocking `must_lock`/`lock`/`must_semaphore`/`semaphore` helpers when
the acquire is still queued after the `max_wait_ms` budget elapses.
"""
struct LockTimeout <: Exception
    keys
    waited_ms
end

Base.showerror(io::IO, e::LockTimeout) =
    print(io, "LockTimeout: waited ", e.waited_ms, "ms for ", join(e.keys, ", "))

"""
    Client(base_url; connect_timeout = 30, read_timeout = 30)

A thin HTTP client for a fiducia endpoint. The trailing slash of `base_url` is
trimmed. Every operation takes the client as its first argument and returns the
parsed JSON response (a `Dict`/`Vector`/scalar, or `nothing` for an empty body).

`connect_timeout` and `read_timeout` bound every request in seconds (pass `0` to
disable). Requests never auto-follow redirects and are never auto-retried, so a
mutating call is issued exactly once and a 3xx surfaces as a `FiduciaError`.
"""
struct Client
    base_url::String
    connect_timeout::Int
    read_timeout::Int

    Client(base_url::AbstractString; connect_timeout::Integer = 30, read_timeout::Integer = 30) =
        new(String(rstrip(base_url, '/')), connect_timeout, read_timeout)
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
    # redirect=false: never auto-follow a 3xx. Following a redirect on a mutating
    # POST/PUT/DELETE could re-submit the operation (duplicate a lock grant / FIFO
    # queue slot); since a 3xx is >= 300 it surfaces as a FiduciaError instead.
    # retry=false: issue each request exactly once (the edge/LB already handles
    # leader redirects, and HTTP.jl otherwise auto-retries idempotent methods).
    resp = HTTP.request(method, c.base_url * path, headers, payload;
        status_exception = false, redirect = false, retry = false,
        connect_timeout = c.connect_timeout, readtimeout = c.read_timeout)
    text = String(resp.body)
    data = _parse_body(text)
    resp.status >= 300 && throw(FiduciaError(resp.status, data))
    return data
end

# A stable holder id when the caller does not supply one.
_gen_holder() = "fdc-" * bytes2hex(rand(UInt8, 16))

# Monotonic clock in milliseconds, for poll deadlines.
_now_ms() = time_ns() / 1_000_000

# The acquire envelope's `result.output` (or an empty Dict if absent).
function _acquire_output(resp)
    resp isa AbstractDict || return Dict{String,Any}()
    r = get(resp, "result", nothing)
    r isa AbstractDict || return Dict{String,Any}()
    o = get(r, "output", nothing)
    return o isa AbstractDict ? o : Dict{String,Any}()
end

# A held grant: exactly what a caller needs to release later.
_grant(key, holder, src) = Dict{String,Any}(
    "key" => key,
    "holder" => holder,
    "fencing_token" => get(src, "fencing_token", nothing),
    "lease_expires_ms" => get(src, "lease_expires_ms", nothing),
    "acquired" => true,
)

# Poll `check` every `retry_interval_ms` until it returns a held grant (non-nothing)
# or the `max_wait_ms` monotonic budget (or `max_retries`) is exhausted — then throw
# `LockTimeout`. `check` runs one GET and returns the grant, or `nothing` to retry.
function _poll_until_held(check, keys, max_wait_ms, retry_interval_ms, max_retries)
    deadline = _now_ms() + max_wait_ms
    attempts = 0
    while max_retries === nothing || attempts < max_retries
        attempts += 1
        remaining = deadline - _now_ms()
        remaining <= 0 && break
        sleep(min(retry_interval_ms, remaining) / 1000)
        grant = check()
        grant === nothing || return grant
    end
    throw(LockTimeout(keys, max_wait_ms))
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

"""
    must_lock(c, key; holder, ttl_ms, max_wait_ms = 30000, retry_interval_ms = 250, max_retries = nothing)
    lock(c, key; ...)

Block until the lock is actually HELD, then return a held-grant `Dict` carrying
`"holder"`, `"fencing_token"` and `"lease_expires_ms"`. The server only reserves a
FIFO slot on `wait = true`, so this polls `lock_get` until this client's `holder`
owns the lock, or throws [`LockTimeout`](@ref) once `max_wait_ms` elapses. A
`holder` is generated when not supplied; release with
`lock_release(c, key, grant["holder"], grant["fencing_token"])`.
"""
function must_lock(c::Client, key; holder = nothing, ttl_ms = nothing,
        max_wait_ms = 30000, retry_interval_ms = 250, max_retries = nothing)
    h = holder === nothing ? _gen_holder() : holder
    out = _acquire_output(lock_acquire(c, key;
        holder = h, ttl_ms = ttl_ms === nothing ? 60000 : ttl_ms, wait = true))
    get(out, "acquired", false) === true && return _grant(key, h, out)
    return _poll_until_held([key], max_wait_ms, retry_interval_ms, max_retries) do
        resp = lock_get(c, key)
        lk = resp isa AbstractDict ? get(resp, "lock", nothing) : nothing
        (lk isa AbstractDict && get(lk, "holder", nothing) == h &&
            get(lk, "fencing_token", nothing) !== nothing) ? _grant(key, h, lk) : nothing
    end
end

# `lock` is the blocking alias of `must_lock`; provided as a method on `Base.lock`
# (Julia already exports `lock`) so `lock(c, key)` just works.
Base.lock(c::Client, key; kwargs...) = must_lock(c, key; kwargs...)

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

"""
    must_semaphore(c, key, limit; holder, ttl_ms, max_wait_ms = 30000, retry_interval_ms = 250, max_retries = nothing)
    semaphore(c, key, limit; ...)

Block until a semaphore permit is actually HELD, then return a held-grant `Dict`
(see [`must_lock`](@ref)). Polls `semaphore_get` for this client's `holder` among
the permit holders, or throws [`LockTimeout`](@ref) once `max_wait_ms` elapses.
"""
function must_semaphore(c::Client, key, limit; holder = nothing, ttl_ms = nothing,
        max_wait_ms = 30000, retry_interval_ms = 250, max_retries = nothing)
    h = holder === nothing ? _gen_holder() : holder
    out = _acquire_output(semaphore_acquire(c, key, limit;
        holder = h, ttl_ms = ttl_ms === nothing ? 60000 : ttl_ms, wait = true))
    get(out, "acquired", false) === true && return _grant(key, h, out)
    return _poll_until_held([key], max_wait_ms, retry_interval_ms, max_retries) do
        resp = semaphore_get(c, key)
        sem = resp isa AbstractDict ? get(resp, "semaphore", nothing) : nothing
        holders = sem isa AbstractDict ? get(sem, "holders", nothing) : nothing
        holders isa AbstractVector || return nothing
        idx = findfirst(holders) do hd
            hd isa AbstractDict && get(hd, "holder", nothing) == h &&
                get(hd, "fencing_token", nothing) !== nothing
        end
        idx === nothing ? nothing : _grant(key, h, holders[idx])
    end
end

semaphore(c::Client, key, limit; kwargs...) = must_semaphore(c, key, limit; kwargs...)

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
