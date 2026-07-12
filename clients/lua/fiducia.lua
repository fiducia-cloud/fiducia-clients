-- Fiducia HTTP client (Lua). Transport: luasocket (socket.http) + luasec (ssl.https); JSON: dkjson.
-- Implements PROTOCOL.md.
--
--   local Fiducia = require("fiducia")
--   local c = Fiducia.new("https://api.fiducia.cloud")
--   local grant = c:must_lock("orders/checkout", { ttl_ms = 30000 })  -- BLOCKS until held
--   -- ... guarded work using grant.fencing_token ...
--   grant.release()   -- or c:lock_release(grant.key, grant.holder, grant.fencing_token)
--
-- Blocking vs try: must_lock/lock and must_semaphore/semaphore POLL until the lock
-- is held or the wait budget elapses (the server queues wait:true acquires and
-- returns immediately -- it does not hold the connection). They return a grant
-- table { key, holder, fencing_token, lease_expires_ms, release() } and raise a
-- timeout table { status = 0, timeout = true, keys, waited_ms, body } on timeout.
-- try_lock/try_semaphore are single-shot (wait:false) and return the raw response.
--
-- Errors: on HTTP status >= 300 (or a transport failure) each op raises a Lua
-- error whose value is a table { status = <number>, body = <parsed JSON | string> }.
-- status is the numeric HTTP code; transport-level failures use status = 0.
-- Callers wrap ops in pcall:
--   local ok, res = pcall(function() return c:status() end)
--   if not ok then print("HTTP " .. tostring(res.status), res.body) else print(res) end
--
-- Deps (LuaRocks): luasocket, luasec, dkjson. Optional fields are omitted from
-- request bodies when nil (CAS-friendly); booleans such as wait are always sent.
--
-- TLS (fail-closed): for https:// the client verifies the server certificate by
-- default (verify = "peer"). A CA bundle is auto-detected at request time from
-- $SSL_CERT_FILE, $SSL_CERT_DIR, then the common OS locations. If verification is
-- on but no CA source is found the request FAILS with a clear error rather than
-- silently connecting insecurely. Override via Fiducia.new(url, { tls = ... }):
-- pass your own cafile/capath, or verify = "none" to opt out (insecure).

local http = require("socket.http")
local socket = require("socket") -- socket.sleep / socket.gettime for the blocking poll loop
local ltn12 = require("ltn12")
local dkjson = require("dkjson")
local https -- luasec (ssl.https); required lazily, only when an https URL is used

-- Percent-encode a string for a path segment or query value: everything except
-- the RFC 3986 unreserved set (A-Z a-z 0-9 - _ . ~) is escaped.
local function enc(s)
  return (tostring(s):gsub("[^%w%-._~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

-- Tag a Lua table so dkjson always encodes it as a JSON object (never [] when
-- empty). Nested arrays (e.g. the keys list) keep dkjson's sequence detection.
local function json_object(t)
  return setmetatable(t or {}, { __jsontype = "object" })
end

local function default_wait(w)
  if w == nil then return true end
  return w
end

local function transport_for(url)
  local scheme = (url:match("^(%a[%w+.-]*)://") or ""):lower()
  if scheme == "https" then
    if not https then https = require("ssl.https") end
    return https, true
  end
  return http, false
end

-- True if a path exists and is openable for reading (works for files and, on
-- Linux/macOS, directories -- fopen() succeeds on a directory there).
local function path_exists(p)
  if not p or p == "" then return false end
  local f = io.open(p, "r")
  if f then f:close(); return true end
  return false
end

-- Auto-detect a CA source. Returns (cafile, capath) with at most one set, trying
-- $SSL_CERT_FILE, $SSL_CERT_DIR, then the common OS bundle/dir locations in order.
local function detect_ca()
  local file_env = os.getenv("SSL_CERT_FILE")
  if path_exists(file_env) then return file_env, nil end
  local dir_env = os.getenv("SSL_CERT_DIR")
  if path_exists(dir_env) then return nil, dir_env end
  local files = {
    "/etc/ssl/cert.pem",                    -- macOS / LibreSSL, some BSDs
    "/etc/ssl/certs/ca-certificates.crt",   -- Debian / Ubuntu / Alpine
    "/etc/pki/tls/certs/ca-bundle.crt",     -- RHEL / Fedora / CentOS
  }
  for _, p in ipairs(files) do
    if path_exists(p) then return p, nil end
  end
  if path_exists("/etc/ssl/certs") then return nil, "/etc/ssl/certs" end
  return nil, nil
end

-- Resolve the effective luasec TLS params for an https request. Verification is
-- ON by default (fail-closed); caller-supplied opts.tls always wins. If verify is
-- on and no CA (opts.tls cafile/capath or auto-detected) is available, raise.
local function resolve_tls(user_tls)
  local params = {}
  if user_tls then
    for k, v in pairs(user_tls) do params[k] = v end
  end
  if params.verify == nil then params.verify = "peer" end
  if params.verify ~= "none" and params.cafile == nil and params.capath == nil then
    local cafile, capath = detect_ca()
    if cafile then
      params.cafile = cafile
    elseif capath then
      params.capath = capath
    else
      error({ status = 0, body =
        "fiducia: HTTPS certificate verification is enabled but no CA bundle was found. "
        .. "Set $SSL_CERT_FILE (a CA bundle file) or $SSL_CERT_DIR (a CA directory), "
        .. "or pass Fiducia.new(url, { tls = { cafile = \"/path/to/ca.pem\" } }). "
        .. "To disable verification (insecure) pass { tls = { verify = \"none\" } }." })
    end
  end
  return params
end

-- --- blocking (must_*) poll-loop helpers ---
-- Defaults for the blocking lock/semaphore helpers (all overridable per call).
local MUST_TTL_MS            = 60000   -- lease requested on the acquire
local MUST_MAX_WAIT_MS       = 30000   -- total time budget for the poll loop
local MUST_RETRY_INTERVAL_MS = 250     -- delay between polls

-- Millisecond clock (luasocket wall clock) used for poll deadlines.
local function now_ms()
  return math.floor(socket.gettime() * 1000)
end

-- A stable, unique holder id, generated when the caller does not supply one.
local function gen_holder()
  return string.format("fdc-%x-%06x", now_ms(), math.random(0, 0xFFFFFF))
end

-- resp.result.output (the acquire grant payload), or {} when absent.
local function output_of(resp)
  local r = type(resp) == "table" and resp.result
  local o = type(r) == "table" and r.output
  return type(o) == "table" and o or {}
end

-- resp.lock (from lock_get), or {} when absent/null.
local function lock_of(resp)
  local lk = type(resp) == "table" and resp.lock
  return type(lk) == "table" and lk or {}
end

-- The holders entry matching `holder` in a semaphore_get response, or nil.
local function find_holder(resp, holder)
  local sem = type(resp) == "table" and resp.semaphore
  local hs = type(sem) == "table" and sem.holders
  if type(hs) == "table" then
    for _, h in ipairs(hs) do
      if type(h) == "table" and h.holder == holder then return h end
    end
  end
  return nil
end

-- The value raised (and pcall-caught) when a blocking helper's budget elapses.
-- Carries status/body (matching the client's error convention) plus timeout=true.
local function timeout_error(keys, waited_ms)
  return {
    status = 0,
    timeout = true,
    keys = keys,
    waited_ms = waited_ms,
    body = "fiducia: timed out after " .. waited_ms .. "ms waiting for " .. table.concat(keys, ", "),
  }
end

local Fiducia = {}
Fiducia.__index = Fiducia
Fiducia._VERSION = "0.1.0"

-- new(base_url [, opts]) -> client. The trailing slash of base_url is trimmed.
-- opts.tls (optional): a table of luasec TLS parameters (verify, cafile, capath,
-- protocol, options, ...) merged into every https request; it always overrides
-- the defaults. https verifies the server certificate by default (verify =
-- "peer") against an auto-detected CA bundle -- pass opts.tls.cafile/capath to
-- point at your own, or opts.tls = { verify = "none" } to opt out (insecure).
-- Ignored for http:// URLs.
function Fiducia.new(base_url, opts)
  opts = opts or {}
  return setmetatable({
    base = (tostring(base_url):gsub("/+$", "")),
    tls = opts.tls,
  }, Fiducia)
end

function Fiducia:_request(method, path, body)
  local url = self.base .. path
  local headers = {}
  local source
  if body ~= nil then
    local encoded, encerr = dkjson.encode(body)
    if not encoded then
      error({ status = 0, body = "fiducia: JSON encode failed: " .. tostring(encerr) })
    end
    source = ltn12.source.string(encoded)
    headers["content-type"] = "application/json"
    headers["content-length"] = tostring(#encoded)
  end

  local chunks = {}
  local transport, is_https = transport_for(url)
  -- Seed the request table with resolved TLS params (https only; fail-closed
  -- verification by default), then set the core fields last so
  -- url/method/headers/source/sink can never be clobbered.
  local reqt = {}
  if is_https then
    for k, v in pairs(resolve_tls(self.tls)) do reqt[k] = v end
  end
  reqt.url = url
  reqt.method = method
  reqt.headers = headers
  reqt.source = source
  reqt.sink = ltn12.sink.table(chunks)
  local ok, code = transport.request(reqt)

  if not ok then
    -- Connection / TLS / DNS failure: `code` holds the error message.
    error({ status = 0, body = "fiducia: request failed: " .. tostring(code) })
  end

  local raw = table.concat(chunks)
  local parsed
  if raw ~= "" then
    local obj, _, decerr = dkjson.decode(raw)
    if decerr then parsed = raw else parsed = obj end
  end

  if type(code) == "number" and code >= 300 then
    error({ status = code, body = parsed })
  end

  return parsed
end

-- --- misc ---
function Fiducia:health()
  return self:_request("GET", "/healthz")
end

function Fiducia:status()
  return self:_request("GET", "/v1/status")
end

-- --- locks ---
function Fiducia:lock_get(key)
  return self:_request("GET", "/v1/locks?key=" .. enc(key))
end

-- opts: { holder, ttl_ms, wait = true }
function Fiducia:lock_acquire(key, opts)
  opts = opts or {}
  local body = json_object({ key = key, wait = default_wait(opts.wait) })
  body.holder = opts.holder
  body.ttl_ms = opts.ttl_ms
  return self:_request("POST", "/v1/locks/acquire", body)
end

-- keys: array of strings (union lock). opts: { holder, ttl_ms, wait = true }
function Fiducia:lock_acquire_many(keys, opts)
  opts = opts or {}
  local body = json_object({ keys = keys, wait = default_wait(opts.wait) })
  body.holder = opts.holder
  body.ttl_ms = opts.ttl_ms
  return self:_request("POST", "/v1/locks/acquire", body)
end

-- opts: { holder, ttl_ms }
function Fiducia:try_lock(key, opts)
  opts = opts or {}
  return self:lock_acquire(key, { holder = opts.holder, ttl_ms = opts.ttl_ms, wait = false })
end

-- Poll check() (returns a grant or nil) every retry_interval_ms until it yields a
-- grant or the max_wait_ms budget elapses; on elapse raise a timeout table. `keys`
-- is only for the timeout message. opts: { max_wait_ms, retry_interval_ms, max_retries }.
function Fiducia:_poll_until(keys, opts, check)
  local max_wait_ms = opts.max_wait_ms or MUST_MAX_WAIT_MS
  local interval_ms = opts.retry_interval_ms or MUST_RETRY_INTERVAL_MS
  local deadline = now_ms() + max_wait_ms
  local attempts = 0
  while opts.max_retries == nil or attempts < opts.max_retries do
    attempts = attempts + 1
    local remaining = deadline - now_ms()
    if remaining <= 0 then break end
    socket.sleep(math.min(interval_ms, remaining) / 1000)
    local grant = check()
    if grant then return grant end
  end
  error(timeout_error(keys, max_wait_ms))
end

-- A held lock grant. grant.release() (or grant:release()) releases it.
function Fiducia:_lock_grant(key, holder, fencing_token, lease_expires_ms)
  local client = self
  return {
    key = key, holder = holder,
    fencing_token = fencing_token, lease_expires_ms = lease_expires_ms,
    release = function() return client:lock_release(key, holder, fencing_token) end,
  }
end

-- must_lock(key, opts) / lock(...): BLOCK until the lock is held, then return the
-- grant. The server queues wait:true acquires and returns immediately, so we poll
-- lock_get until we hold it (our holder + a fencing_token) or the wait budget
-- elapses -- on which it raises a timeout table (callers pcall). try_lock is
-- single-shot and unaffected.
-- opts: { holder, ttl_ms, max_wait_ms = 30000, retry_interval_ms = 250, max_retries }.
function Fiducia:must_lock(key, opts)
  opts = opts or {}
  local holder = opts.holder or gen_holder()
  local out = output_of(self:lock_acquire(key,
    { holder = holder, ttl_ms = opts.ttl_ms or MUST_TTL_MS, wait = true }))
  if out.acquired then
    return self:_lock_grant(key, holder, out.fencing_token, out.lease_expires_ms)
  end
  return self:_poll_until({ key }, opts, function()
    local lk = lock_of(self:lock_get(key))
    if lk.holder == holder and lk.fencing_token ~= nil then
      return self:_lock_grant(key, holder, lk.fencing_token, lk.lease_expires_ms)
    end
  end)
end
Fiducia.lock = Fiducia.must_lock

-- key is accepted for symmetry but intentionally NOT sent in the body.
function Fiducia:lock_release(key, holder, fencing_token)
  return self:_request("POST", "/v1/locks/release",
    json_object({ holder = holder, fencing_token = fencing_token }))
end

-- --- semaphores ---
function Fiducia:semaphore_get(key)
  return self:_request("GET", "/v1/semaphores?key=" .. enc(key))
end

-- opts: { holder, ttl_ms, wait = true }
function Fiducia:semaphore_acquire(key, limit, opts)
  opts = opts or {}
  local body = json_object({ key = key, limit = limit, wait = default_wait(opts.wait) })
  body.holder = opts.holder
  body.ttl_ms = opts.ttl_ms
  return self:_request("POST", "/v1/semaphores/acquire", body)
end

-- opts: { holder, ttl_ms }
function Fiducia:try_semaphore(key, limit, opts)
  opts = opts or {}
  return self:semaphore_acquire(key, limit, { holder = opts.holder, ttl_ms = opts.ttl_ms, wait = false })
end

-- A held semaphore permit. grant.release() releases it.
function Fiducia:_semaphore_grant(key, holder, fencing_token, lease_expires_ms)
  local client = self
  return {
    key = key, holder = holder,
    fencing_token = fencing_token, lease_expires_ms = lease_expires_ms,
    release = function() return client:semaphore_release(key, holder, fencing_token) end,
  }
end

-- must_semaphore(key, limit, opts) / semaphore(...): BLOCK until a permit is held,
-- polling semaphore_get for our holder (with a fencing_token) until held or the wait
-- budget elapses -- on which it raises a timeout table (callers pcall). try_semaphore
-- is single-shot and unaffected.
-- opts: { holder, ttl_ms, max_wait_ms = 30000, retry_interval_ms = 250, max_retries }.
function Fiducia:must_semaphore(key, limit, opts)
  opts = opts or {}
  local holder = opts.holder or gen_holder()
  local out = output_of(self:semaphore_acquire(key, limit,
    { holder = holder, ttl_ms = opts.ttl_ms or MUST_TTL_MS, wait = true }))
  if out.acquired then
    return self:_semaphore_grant(key, holder, out.fencing_token, out.lease_expires_ms)
  end
  return self:_poll_until({ key }, opts, function()
    local slot = find_holder(self:semaphore_get(key), holder)
    if slot and slot.fencing_token ~= nil then
      return self:_semaphore_grant(key, holder, slot.fencing_token, slot.lease_expires_ms)
    end
  end)
end
Fiducia.semaphore = Fiducia.must_semaphore

function Fiducia:semaphore_release(key, holder, fencing_token)
  return self:_request("POST", "/v1/semaphores/release",
    json_object({ key = key, holder = holder, fencing_token = fencing_token }))
end

-- --- idempotency ---
function Fiducia:idempotency_get(key)
  return self:_request("GET", "/v1/idempotency?key=" .. enc(key))
end

-- opts: { owner, ttl_ms, ttl, metadata } (metadata = arbitrary JSON object)
function Fiducia:idempotency_claim(key, opts)
  opts = opts or {}
  local body = json_object({ key = key })
  body.owner = opts.owner
  body.ttl_ms = opts.ttl_ms
  body.ttl = opts.ttl
  body.metadata = opts.metadata
  return self:_request("POST", "/v1/idempotency/claim", body)
end

-- result (optional) = arbitrary JSON object
function Fiducia:idempotency_complete(key, owner, fencing_token, result)
  local body = json_object({ key = key, owner = owner, fencing_token = fencing_token })
  body.result = result
  return self:_request("POST", "/v1/idempotency/complete", body)
end

-- --- reader-writer locks ---
-- opts: { ttl_ms, wait = true }
function Fiducia:rw_acquire_read(key, opts)
  opts = opts or {}
  local body = json_object({ wait = default_wait(opts.wait) })
  body.ttl_ms = opts.ttl_ms
  return self:_request("POST", "/v1/rw/" .. enc(key) .. "/read", body)
end

function Fiducia:rw_end_read(key, lock_id)
  return self:_request("POST", "/v1/rw/" .. enc(key) .. "/read/end",
    json_object({ lock_id = lock_id }))
end

-- opts: { ttl_ms, wait = true }
function Fiducia:rw_acquire_write(key, opts)
  opts = opts or {}
  local body = json_object({ wait = default_wait(opts.wait) })
  body.ttl_ms = opts.ttl_ms
  return self:_request("POST", "/v1/rw/" .. enc(key) .. "/write", body)
end

function Fiducia:rw_end_write(key, lock_id)
  return self:_request("POST", "/v1/rw/" .. enc(key) .. "/write/end",
    json_object({ lock_id = lock_id }))
end

-- --- config KV ---
function Fiducia:kv_get(key)
  return self:_request("GET", "/v1/kv?key=" .. enc(key))
end

-- value = arbitrary JSON. opts: { ttl_ms, prev_revision }
function Fiducia:kv_put(key, value, opts)
  opts = opts or {}
  local body = json_object({ value = value })
  body.ttl_ms = opts.ttl_ms
  body.prev_revision = opts.prev_revision
  return self:_request("PUT", "/v1/kv?key=" .. enc(key), body)
end

function Fiducia:kv_delete(key)
  return self:_request("DELETE", "/v1/kv?key=" .. enc(key))
end

function Fiducia:kv_list(prefix)
  return self:_request("GET", "/v1/kv?prefix=" .. enc(prefix))
end

-- --- rate limiting ---
function Fiducia:rate_limit_get(tenant, key)
  return self:_request("GET", "/v1/rate-limit/" .. enc(tenant) .. "/" .. enc(key))
end

-- opts: { refill_per_second, cost }
function Fiducia:rate_limit_check(tenant, key, algorithm, limit, window_ms, opts)
  opts = opts or {}
  local body = json_object({ algorithm = algorithm, limit = limit, window_ms = window_ms })
  body.refill_per_second = opts.refill_per_second
  body.cost = opts.cost
  return self:_request("POST",
    "/v1/rate-limit/" .. enc(tenant) .. "/" .. enc(key) .. "/check", body)
end

-- --- cron & scheduling ---
function Fiducia:schedule_get(name)
  return self:_request("GET", "/v1/cron/schedules/" .. enc(name))
end

-- target = arbitrary JSON object (e.g. { kind = "webhook", url = "..." }).
-- opts: { cron, one_shot_at_ms, delivery, max_retries }
function Fiducia:schedule_upsert(name, target, opts)
  opts = opts or {}
  local body = json_object({ target = target })
  body.cron = opts.cron
  body.one_shot_at_ms = opts.one_shot_at_ms
  body.delivery = opts.delivery
  body.max_retries = opts.max_retries
  return self:_request("PUT", "/v1/cron/schedules/" .. enc(name), body)
end

function Fiducia:schedule_record_run(name, fire_id, fired_at_ms)
  local body = json_object({ fire_id = fire_id })
  body.fired_at_ms = fired_at_ms
  return self:_request("POST", "/v1/cron/schedules/" .. enc(name) .. "/runs", body)
end

function Fiducia:schedule_history(name)
  return self:_request("GET", "/v1/cron/schedules/" .. enc(name) .. "/history")
end

-- --- leader election ---
function Fiducia:election_get(name)
  return self:_request("GET", "/v1/elections/" .. enc(name))
end

-- metadata (optional) = arbitrary JSON object
function Fiducia:election_campaign(name, candidate, ttl_ms, metadata)
  local body = json_object({ candidate = candidate, ttl_ms = ttl_ms })
  body.metadata = metadata
  return self:_request("POST", "/v1/elections/" .. enc(name) .. "/campaign", body)
end

function Fiducia:election_renew(name, candidate, fencing_token)
  return self:_request("POST", "/v1/elections/" .. enc(name) .. "/renew",
    json_object({ candidate = candidate, fencing_token = fencing_token }))
end

function Fiducia:election_resign(name, candidate, fencing_token)
  return self:_request("POST", "/v1/elections/" .. enc(name) .. "/resign",
    json_object({ candidate = candidate, fencing_token = fencing_token }))
end

-- --- service discovery ---
function Fiducia:service_instances(service)
  return self:_request("GET", "/v1/services/" .. enc(service))
end

-- metadata (optional) = arbitrary JSON object
function Fiducia:service_register(service, instance_id, address, ttl_ms, metadata)
  local body = json_object({ address = address, ttl_ms = ttl_ms })
  body.metadata = metadata
  return self:_request("PUT",
    "/v1/services/" .. enc(service) .. "/instances/" .. enc(instance_id), body)
end

function Fiducia:service_heartbeat(service, instance_id, ttl_ms)
  local body = json_object({})
  body.ttl_ms = ttl_ms
  return self:_request("POST",
    "/v1/services/" .. enc(service) .. "/instances/" .. enc(instance_id) .. "/heartbeat", body)
end

function Fiducia:service_deregister(service, instance_id)
  return self:_request("DELETE",
    "/v1/services/" .. enc(service) .. "/instances/" .. enc(instance_id))
end

function Fiducia:service_list()
  return self:_request("GET", "/v1/services")
end

return Fiducia
