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

    def must_semaphore(key : String, limit : Int64, holder : String? = nil, ttl_ms : Int64? = nil) : JSON::Any
      semaphore_acquire(key, limit, holder: holder, ttl_ms: ttl_ms, wait: true)
    end

    def semaphore(key : String, limit : Int64, holder : String? = nil, ttl_ms : Int64? = nil) : JSON::Any
      must_semaphore(key, limit, holder: holder, ttl_ms: ttl_ms)
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
