-- Fiducia HTTP client (Lua). Transport: luasocket (socket.http) + luasec (ssl.https); JSON: dkjson.
-- Implements PROTOCOL.md.
--
--   local Fiducia = require("fiducia")
--   local c = Fiducia.new("https://api.fiducia.cloud")
--   local lock = c:lock_acquire("orders/checkout", { ttl_ms = 30000 })
--   c:lock_release("orders/checkout", "worker-a", lock.result.output.fencing_token)
--
-- Errors: on HTTP status >= 300 (or a transport failure) each op raises a Lua
-- error whose value is a table { status = <number>, body = <parsed JSON | string> }.
-- status is the numeric HTTP code; transport-level failures use status = 0.
-- Redirects are NOT followed: a 3xx surfaces as an error rather than replaying
-- the request (and its headers) to the Location.
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
  -- Hard-reject redirects: luasocket follows 3xx by default, which would replay
  -- this (possibly mutating) request and its auth/idempotency headers to the
  -- Location -- including an https->http downgrade. Disable following so a
  -- redirect instead surfaces as the >=300 error raised below.
  reqt.redirect = false
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

-- opts: { holder, ttl_ms }
function Fiducia:must_lock(key, opts)
  opts = opts or {}
  return self:lock_acquire(key, { holder = opts.holder, ttl_ms = opts.ttl_ms, wait = true })
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

-- opts: { holder, ttl_ms }
function Fiducia:must_semaphore(key, limit, opts)
  opts = opts or {}
  return self:semaphore_acquire(key, limit, { holder = opts.holder, ttl_ms = opts.ttl_ms, wait = true })
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
