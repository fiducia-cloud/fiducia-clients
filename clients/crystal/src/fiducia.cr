# Fiducia HTTP client (Crystal). Zero-dependency — stdlib HTTP::Client + JSON.
# Implements PROTOCOL.md.
#
#   require "./fiducia"
#   c = Fiducia::Client.new("https://api.fiducia.cloud")
#   lock = c.lock_acquire("orders/checkout", holder: "worker-a", ttl_ms: 30_000)
#   c.lock_release("orders/checkout", "worker-a", lock["result"]["output"]["fencing_token"].as_i64)

require "http/client"
require "json"
require "uri"

module Fiducia
  VERSION = "0.1.0"

  # Raised when the server responds with an HTTP status >= 300. Carries the
  # numeric +status+ and the parsed JSON +body+ (a null JSON::Any when empty).
  class Error < Exception
    getter status : Int32
    getter body : JSON::Any?

    def initialize(@status : Int32, @body : JSON::Any?)
      super("fiducia: HTTP #{@status}")
    end
  end

  # Raised by the blocking helpers (+must_lock+/+lock+, +must_semaphore+/
  # +semaphore+) when the wait budget elapses before the grant is held. Distinct
  # from Fiducia::Error (which is an HTTP status) — a timeout carries no status.
  class Timeout < Exception
    getter keys : Array(String)
    getter waited_ms : Int64

    def initialize(@keys : Array(String), @waited_ms : Int64)
      super("fiducia: timed out after #{@waited_ms}ms waiting for #{@keys.join(", ")}")
    end
  end

  # Thin HTTP wrapper over the fiducia contract. Every method returns the parsed
  # JSON response as a JSON::Any (an empty body decodes to a null JSON::Any), and
  # raises Fiducia::Error on any status >= 300. Optional params are omitted from
  # the request body when nil, which preserves compare-and-set semantics.
  class Client
    def initialize(base_url : String, @request_timeout : Time::Span? = nil)
      @base = base_url.rstrip('/')
    end

    # --- misc ---
    def health : JSON::Any
      request("GET", "/healthz")
    end

    def status : JSON::Any
      request("GET", "/v1/status")
    end

    # --- locks (single-key + multi-key UNION locks) ---
    def lock_get(key : String) : JSON::Any
      request("GET", "/v1/locks?key=#{enc_query(key)}")
    end

    def lock_acquire(key : String, holder : String? = nil, ttl_ms : Int64? = nil, wait : Bool = true) : JSON::Any
      request("POST", "/v1/locks/acquire", build_body(key: key, holder: holder, ttl_ms: ttl_ms, wait: wait))
    end

    # Multi-key UNION lock: all-or-nothing across the set; conflicts on any member.
    def lock_acquire_many(keys : Array(String), holder : String? = nil, ttl_ms : Int64? = nil, wait : Bool = true) : JSON::Any
      request("POST", "/v1/locks/acquire", build_body(keys: keys, holder: holder, ttl_ms: ttl_ms, wait: wait))
    end

    def try_lock(key : String, holder : String? = nil, ttl_ms : Int64? = nil) : JSON::Any
      lock_acquire(key, holder: holder, ttl_ms: ttl_ms, wait: false)
    end

    # Block until the lock is actually HELD, or raise Fiducia::Timeout. The
    # server does not hold the connection on wait:true — it reserves a FIFO slot
    # and returns immediately — so we poll lock_get until we own the grant. On
    # success returns a normalized held-grant JSON::Any
    # ({holder, fencing_token, lease_expires_ms}); release it via lock_release.
    def must_lock(key : String, holder : String? = nil, ttl_ms : Int64? = nil,
                  max_wait_ms : Int32 = 30_000, retry_interval_ms : Int32 = 250,
                  max_retries : Int32? = nil) : JSON::Any
      poll_lock(key, holder, ttl_ms, max_wait_ms, retry_interval_ms, max_retries)
    end

    def lock(key : String, holder : String? = nil, ttl_ms : Int64? = nil,
             max_wait_ms : Int32 = 30_000, retry_interval_ms : Int32 = 250,
             max_retries : Int32? = nil) : JSON::Any
      must_lock(key, holder: holder, ttl_ms: ttl_ms, max_wait_ms: max_wait_ms,
        retry_interval_ms: retry_interval_ms, max_retries: max_retries)
    end

    # +key+ is accepted for call-site symmetry; the grant is released by token.
    def lock_release(key : String, holder : String, fencing_token : Int64) : JSON::Any
      request("POST", "/v1/locks/release", build_body(holder: holder, fencing_token: fencing_token))
    end

    # --- semaphores (counting: up to +limit+ concurrent holders) ---
    def semaphore_get(key : String) : JSON::Any
      request("GET", "/v1/semaphores?key=#{enc_query(key)}")
    end

    def semaphore_acquire(key : String, limit : Int64, holder : String? = nil, ttl_ms : Int64? = nil, wait : Bool = true) : JSON::Any
      request("POST", "/v1/semaphores/acquire", build_body(key: key, holder: holder, ttl_ms: ttl_ms, limit: limit, wait: wait))
    end

    def try_semaphore(key : String, limit : Int64, holder : String? = nil, ttl_ms : Int64? = nil) : JSON::Any
      semaphore_acquire(key, limit, holder: holder, ttl_ms: ttl_ms, wait: false)
    end

    # Block until a semaphore permit is actually HELD, or raise Fiducia::Timeout.
    # Polls semaphore_get for our holder entry (see must_lock). Returns a
    # normalized held-grant JSON::Any; release it via semaphore_release.
    def must_semaphore(key : String, limit : Int64, holder : String? = nil, ttl_ms : Int64? = nil,
                       max_wait_ms : Int32 = 30_000, retry_interval_ms : Int32 = 250,
                       max_retries : Int32? = nil) : JSON::Any
      poll_semaphore(key, limit, holder, ttl_ms, max_wait_ms, retry_interval_ms, max_retries)
    end

    def semaphore(key : String, limit : Int64, holder : String? = nil, ttl_ms : Int64? = nil,
                  max_wait_ms : Int32 = 30_000, retry_interval_ms : Int32 = 250,
                  max_retries : Int32? = nil) : JSON::Any
      must_semaphore(key, limit, holder: holder, ttl_ms: ttl_ms, max_wait_ms: max_wait_ms,
        retry_interval_ms: retry_interval_ms, max_retries: max_retries)
    end

    def semaphore_release(key : String, holder : String, fencing_token : Int64) : JSON::Any
      request("POST", "/v1/semaphores/release", build_body(key: key, holder: holder, fencing_token: fencing_token))
    end

    # --- idempotency keys ---
    def idempotency_get(key : String) : JSON::Any
      request("GET", "/v1/idempotency?key=#{enc_query(key)}")
    end

    def idempotency_claim(key : String, owner : String? = nil, ttl_ms : Int64? = nil, ttl : String? = nil, metadata : JSON::Any? = nil) : JSON::Any
      request("POST", "/v1/idempotency/claim", build_body(key: key, owner: owner, ttl_ms: ttl_ms, ttl: ttl, metadata: metadata))
    end

    def idempotency_complete(key : String, owner : String, fencing_token : Int64, result : JSON::Any? = nil) : JSON::Any
      request("POST", "/v1/idempotency/complete", build_body(key: key, owner: owner, fencing_token: fencing_token, result: result))
    end

    # --- reader-writer locks ---
    def rw_acquire_read(key : String, ttl_ms : Int64? = nil, wait : Bool = true) : JSON::Any
      request("POST", "/v1/rw/#{enc_path(key)}/read", build_body(ttl_ms: ttl_ms, wait: wait))
    end

    def rw_end_read(key : String, lock_id : String) : JSON::Any
      request("POST", "/v1/rw/#{enc_path(key)}/read/end", build_body(lock_id: lock_id))
    end

    def rw_acquire_write(key : String, ttl_ms : Int64? = nil, wait : Bool = true) : JSON::Any
      request("POST", "/v1/rw/#{enc_path(key)}/write", build_body(ttl_ms: ttl_ms, wait: wait))
    end

    def rw_end_write(key : String, lock_id : String) : JSON::Any
      request("POST", "/v1/rw/#{enc_path(key)}/write/end", build_body(lock_id: lock_id))
    end

    # --- config KV (keys are ?key=, slash-safe) ---
    def kv_get(key : String) : JSON::Any
      request("GET", "/v1/kv?key=#{enc_query(key)}")
    end

    def kv_put(key : String, value : String, ttl_ms : Int64? = nil, prev_revision : Int64? = nil) : JSON::Any
      request("PUT", "/v1/kv?key=#{enc_query(key)}", build_body(value: value, ttl_ms: ttl_ms, prev_revision: prev_revision))
    end

    def kv_delete(key : String) : JSON::Any
      request("DELETE", "/v1/kv?key=#{enc_query(key)}")
    end

    def kv_list(prefix : String) : JSON::Any
      request("GET", "/v1/kv?prefix=#{enc_query(prefix)}")
    end

    # --- rate limiting ---
    def rate_limit_get(tenant : String, key : String) : JSON::Any
      request("GET", "/v1/rate-limit/#{enc_path(tenant)}/#{enc_path(key)}")
    end

    def rate_limit_check(tenant : String, key : String, algorithm : String, limit : Int64, window_ms : Int64, refill_per_second : Float64? = nil, cost : Int64? = nil) : JSON::Any
      request("POST", "/v1/rate-limit/#{enc_path(tenant)}/#{enc_path(key)}/check", build_body(algorithm: algorithm, limit: limit, window_ms: window_ms, refill_per_second: refill_per_second, cost: cost))
    end

    # --- cron & scheduling ---
    def schedule_get(name : String) : JSON::Any
      request("GET", "/v1/cron/schedules/#{enc_path(name)}")
    end

    def schedule_upsert(name : String, target : JSON::Any, cron : String? = nil, one_shot_at_ms : Int64? = nil, delivery : String? = nil, max_retries : Int64? = nil) : JSON::Any
      request("PUT", "/v1/cron/schedules/#{enc_path(name)}", build_body(target: target, cron: cron, one_shot_at_ms: one_shot_at_ms, delivery: delivery, max_retries: max_retries))
    end

    def schedule_record_run(name : String, fire_id : String, fired_at_ms : Int64? = nil) : JSON::Any
      request("POST", "/v1/cron/schedules/#{enc_path(name)}/runs", build_body(fire_id: fire_id, fired_at_ms: fired_at_ms))
    end

    def schedule_history(name : String) : JSON::Any
      request("GET", "/v1/cron/schedules/#{enc_path(name)}/history")
    end

    # --- leader election ---
    def election_get(name : String) : JSON::Any
      request("GET", "/v1/elections/#{enc_path(name)}")
    end

    def election_campaign(name : String, candidate : String, ttl_ms : Int64, metadata : JSON::Any? = nil) : JSON::Any
      request("POST", "/v1/elections/#{enc_path(name)}/campaign", build_body(candidate: candidate, ttl_ms: ttl_ms, metadata: metadata))
    end

    def election_renew(name : String, candidate : String, fencing_token : Int64) : JSON::Any
      request("POST", "/v1/elections/#{enc_path(name)}/renew", build_body(candidate: candidate, fencing_token: fencing_token))
    end

    def election_resign(name : String, candidate : String, fencing_token : Int64) : JSON::Any
      request("POST", "/v1/elections/#{enc_path(name)}/resign", build_body(candidate: candidate, fencing_token: fencing_token))
    end

    # --- service discovery ---
    def service_instances(service : String) : JSON::Any
      request("GET", "/v1/services/#{enc_path(service)}")
    end

    def service_register(service : String, instance_id : String, address : String, ttl_ms : Int64, metadata : JSON::Any? = nil) : JSON::Any
      request("PUT", "/v1/services/#{enc_path(service)}/instances/#{enc_path(instance_id)}", build_body(address: address, ttl_ms: ttl_ms, metadata: metadata))
    end

    def service_heartbeat(service : String, instance_id : String, ttl_ms : Int64? = nil) : JSON::Any
      request("POST", "/v1/services/#{enc_path(service)}/instances/#{enc_path(instance_id)}/heartbeat", build_body(ttl_ms: ttl_ms))
    end

    def service_deregister(service : String, instance_id : String) : JSON::Any
      request("DELETE", "/v1/services/#{enc_path(service)}/instances/#{enc_path(instance_id)}")
    end

    def service_list : JSON::Any
      request("GET", "/v1/services")
    end

    # --- internals ---

    # Default lease when the caller does not supply ttl_ms to a blocking helper.
    DEFAULT_TTL_MS = 60_000_i64

    # Reserve a FIFO slot (wait:true) then poll lock_get until we hold +key+, or
    # raise Fiducia::Timeout once the wait budget / max_retries is spent.
    private def poll_lock(key : String, holder : String?, ttl_ms : Int64?,
                          max_wait_ms : Int32, retry_interval_ms : Int32, max_retries : Int32?) : JSON::Any
      hold = holder || gen_holder
      acq_out = nav_output(lock_acquire(key, holder: hold, ttl_ms: ttl_ms || DEFAULT_TTL_MS, wait: true))
      return held_grant(hold, acq_out) if acquired?(acq_out)

      deadline = Time.monotonic + max_wait_ms.milliseconds
      attempts = 0
      loop do
        break if (mr = max_retries) && attempts >= mr
        attempts += 1
        remaining = deadline - Time.monotonic
        break if remaining <= Time::Span.zero
        sleep(remaining < retry_interval_ms.milliseconds ? remaining : retry_interval_ms.milliseconds)

        lk = lock_get(key)["lock"]?
        if lk && lk["holder"]?.try(&.as_s?) == hold && present?(lk["fencing_token"]?)
          return held_grant(hold, lk)
        end
      end
      raise Timeout.new([key], max_wait_ms.to_i64)
    end

    # Reserve a permit (wait:true) then poll semaphore_get for our holder entry.
    private def poll_semaphore(key : String, limit : Int64, holder : String?, ttl_ms : Int64?,
                               max_wait_ms : Int32, retry_interval_ms : Int32, max_retries : Int32?) : JSON::Any
      hold = holder || gen_holder
      acq_out = nav_output(semaphore_acquire(key, limit, holder: hold, ttl_ms: ttl_ms || DEFAULT_TTL_MS, wait: true))
      return held_grant(hold, acq_out) if acquired?(acq_out)

      deadline = Time.monotonic + max_wait_ms.milliseconds
      attempts = 0
      loop do
        break if (mr = max_retries) && attempts >= mr
        attempts += 1
        remaining = deadline - Time.monotonic
        break if remaining <= Time::Span.zero
        sleep(remaining < retry_interval_ms.milliseconds ? remaining : retry_interval_ms.milliseconds)

        holders = semaphore_get(key)["semaphore"]?.try(&.["holders"]?).try(&.as_a?)
        if holders
          slot = holders.find { |h| h["holder"]?.try(&.as_s?) == hold && present?(h["fencing_token"]?) }
          return held_grant(hold, slot) if slot
        end
      end
      raise Timeout.new([key], max_wait_ms.to_i64)
    end

    # A stable, unique holder id when the caller supplies none.
    private def gen_holder : String
      "fdc-#{Random::Secure.hex(16)}"
    end

    # Navigate resp["result"]["output"] safely; missing links -> null JSON::Any.
    private def nav_output(resp : JSON::Any) : JSON::Any
      resp["result"]?.try(&.["output"]?) || JSON::Any.new(nil)
    end

    # True only when the acquire output reports the grant is held now.
    private def acquired?(out : JSON::Any) : Bool
      out["acquired"]?.try(&.as_bool?) == true
    end

    # A JSON value is "present" iff it exists and is not JSON null.
    private def present?(value : JSON::Any?) : Bool
      !(value.nil? || value.raw.nil?)
    end

    # Normalize a held grant (from acquire output or a lock/holder entry) into a
    # stable {holder, fencing_token, lease_expires_ms} JSON::Any the caller can
    # release. fencing_token stays a JSON::Any so 64-bit values keep full precision.
    private def held_grant(holder : String, src : JSON::Any) : JSON::Any
      JSON::Any.new({
        "holder"           => JSON::Any.new(holder),
        "fencing_token"    => src["fencing_token"]? || JSON::Any.new(nil),
        "lease_expires_ms" => src["lease_expires_ms"]? || JSON::Any.new(nil),
      } of String => JSON::Any)
    end

    # Percent-encode a value for use in a query string (form encoding).
    private def enc_query(value : String) : String
      URI.encode_www_form(value)
    end

    # Percent-encode a value for use as a single path segment (slashes escaped).
    private def enc_path(value : String) : String
      URI.encode_path_segment(value)
    end

    # Build a JSON object body, dropping any field whose value is nil so that
    # optional params are omitted from the wire.
    private def build_body(**fields) : String
      JSON.build do |json|
        json.object do
          fields.each do |key, value|
            next if value.nil?
            json.field key.to_s, value
          end
        end
      end
    end

    private def request(method : String, path : String, body : String? = nil) : JSON::Any
      uri = URI.parse(@base + path)
      client = HTTP::Client.new(uri)
      if timeout = @request_timeout
        client.connect_timeout = timeout
        client.read_timeout = timeout
        client.write_timeout = timeout
      end

      response = begin
        headers = HTTP::Headers.new
        headers["Content-Type"] = "application/json" if body
        client.exec(method, uri.request_target, headers, body)
      ensure
        client.close
      end

      data = parse_body(response.body)
      raise Error.new(response.status_code, data) if response.status_code >= 300
      data
    end

    # Decode a response body into JSON::Any. An empty body (e.g. 204) becomes a
    # null JSON::Any; a body that is not valid JSON (e.g. a plain-text proxy
    # error accompanying a 5xx) falls back to the raw text rather than raising a
    # JSON::ParseException, so the caller always sees a Fiducia::Error carrying
    # the status and whatever the server sent.
    private def parse_body(text : String) : JSON::Any
      return JSON::Any.new(nil) if text.empty?
      JSON.parse(text)
    rescue JSON::ParseException
      JSON::Any.new(text)
    end
  end
end
