# Fiducia HTTP client (Ruby). Zero-dependency — stdlib net/http + json.
# Implements PROTOCOL.md.
#
#   require_relative "fiducia"
#   c = Fiducia::Client.new("https://api.fiducia.cloud")
#   lock = c.lock_acquire("orders/checkout", ttl_ms: 30000)
#   c.lock_release("orders/checkout", "worker-a", lock["result"]["output"]["fencing_token"])

require "net/http"
require "json"
require "securerandom"
require "uri"
require "timeout"

module Fiducia
  class Error < StandardError
    attr_reader :status, :body
    def initialize(status, body)
      super("fiducia: HTTP #{status}")
      @status = status
      @body = body
    end
  end

  # Raised by the blocking +lock+/+acquire_semaphore+ when the wait budget elapses.
  class LockTimeout < StandardError
    attr_reader :keys, :waited_ms
    def initialize(keys, waited_ms)
      super("fiducia: timed out after #{waited_ms}ms waiting for #{keys.join(', ')}")
      @keys = keys
      @waited_ms = waited_ms
    end
  end

  # A held lock grant. Call +release+ (alias +unlock+) when done.
  Lock = Struct.new(:client, :keys, :holder, :fencing_token, :lease_expires_ms) do
    def release; client.lock_release(holder, fencing_token); end
    alias_method :unlock, :release
  end

  # A held semaphore permit. Call +release+ when done.
  SemaphoreHandle = Struct.new(:client, :key, :holder, :fencing_token, :lease_expires_ms) do
    def release; client.semaphore_release(key, holder, fencing_token); end
    alias_method :unlock, :release
  end

  class Client
    attr_accessor :request_timeout, :lock_request_timeout, :retry_max, :retry_delay

    def initialize(base_url)
      @base = base_url.sub(%r{/+\z}, "")
      @request_timeout = nil
      @lock_request_timeout = nil
      @retry_max = 0
      @retry_delay = 0
    end

    # --- misc ---
    def health; request("GET", "/healthz"); end
    def status; request("GET", "/v1/status"); end

    # --- locks & semaphores ---
    def lock_acquire(key, ttl_ms: nil, wait: true, max: 1, **opts)
      lock_acquire_with_wait(key, ttl_ms: ttl_ms, wait: wait, max: max, opts: opts)
    end
    def try_lock(key, ttl_ms: nil, max: 1, **opts)
      lock_acquire_with_wait(key, ttl_ms: ttl_ms, wait: false, max: max, opts: opts)
    end
    def must_lock(key, ttl_ms: nil, max: 1, **opts)
      lock_acquire_with_wait(key, ttl_ms: ttl_ms, wait: true, max: max, opts: opts)
    end
    alias lock must_lock
    def lock_acquire_with_wait(key, ttl_ms:, wait:, max:, opts:)
      request("POST", "/v1/locks/acquire", { key: key, ttl_ms: ttl_ms, wait: wait, max: max }, opts: opts, lock_acquire: true)
    end
    def lock_release(key, holder, fencing_token)
      request("POST", "/v1/locks/release", { holder: holder, fencing_token: fencing_token })
    end
    def semaphore_acquire(key, ttl_ms: nil, wait: true, max: 2, **opts)
      semaphore_acquire_with_wait(key, ttl_ms: ttl_ms, wait: wait, max: max, opts: opts)
    end
    def try_semaphore(key, ttl_ms: nil, max: 2, **opts)
      semaphore_acquire_with_wait(key, ttl_ms: ttl_ms, wait: false, max: max, opts: opts)
    end
    def must_semaphore(key, ttl_ms: nil, max: 2, **opts)
      semaphore_acquire_with_wait(key, ttl_ms: ttl_ms, wait: true, max: max, opts: opts)
    end
    alias semaphore must_semaphore
    def semaphore_acquire_with_wait(key, ttl_ms:, wait:, max:, opts:)
      request("POST", "/v1/semaphores/acquire", { key: key, ttl_ms: ttl_ms, wait: wait, limit: [max, 2].max }, opts: opts, lock_acquire: true)
    end
    def semaphore_release(key, holder, fencing_token)
      request("POST", "/v1/semaphores/release", { key: key, holder: holder, fencing_token: fencing_token })
    end

    # --- reader-writer locks ---
    def rw_acquire_read(key, ttl_ms: nil, wait: true)
      request("POST", "/v1/rw/#{enc key}/read", { ttl_ms: ttl_ms, wait: wait })
    end
    def rw_end_read(key, lock_id)
      request("POST", "/v1/rw/#{enc key}/read/end", { lock_id: lock_id })
    end
    def rw_acquire_write(key, ttl_ms: nil, wait: true)
      request("POST", "/v1/rw/#{enc key}/write", { ttl_ms: ttl_ms, wait: wait })
    end
    def rw_end_write(key, lock_id)
      request("POST", "/v1/rw/#{enc key}/write/end", { lock_id: lock_id })
    end

    # --- config KV ---
    def kv_get(key); request("GET", "/v1/kv?key=#{enc key}"); end
    def kv_put(key, value, ttl_ms: nil)
      request("PUT", "/v1/kv?key=#{enc key}", { value: value, ttl_ms: ttl_ms })
    end
    def kv_delete(key); request("DELETE", "/v1/kv?key=#{enc key}"); end
    def kv_list(prefix); request("GET", "/v1/kv?prefix=#{enc prefix}"); end

    # --- leader election ---
    def election_campaign(name, candidate, ttl_ms)
      request("POST", "/v1/elections/#{enc name}/campaign", { candidate: candidate, ttl_ms: ttl_ms })
    end
    def election_renew(name, candidate, fencing_token)
      request("POST", "/v1/elections/#{enc name}/renew", { candidate: candidate, fencing_token: fencing_token })
    end
    def election_resign(name, candidate, fencing_token)
      request("POST", "/v1/elections/#{enc name}/resign", { candidate: candidate, fencing_token: fencing_token })
    end
    def election_get(name); request("GET", "/v1/elections/#{enc name}"); end

    # --- service discovery ---
    def service_register(service, instance_id, address, ttl_ms)
      request("PUT", "/v1/services/#{enc service}/instances/#{enc instance_id}", { address: address, ttl_ms: ttl_ms })
    end
    def service_heartbeat(service, instance_id)
      request("POST", "/v1/services/#{enc service}/instances/#{enc instance_id}/heartbeat")
    end
    def service_deregister(service, instance_id)
      request("DELETE", "/v1/services/#{enc service}/instances/#{enc instance_id}")
    end
    def service_instances(service); request("GET", "/v1/services/#{enc service}"); end
    def service_list; request("GET", "/v1/services"); end

    private

    def _gen_holder; "fdc-#{SecureRandom.uuid}"; end

    def _output(resp)
      ((resp || {})["result"] || {})["output"] || {}
    end

    def _acquire_lock(keys, wait, ttl_ms, holder, max_wait_ms, retry_interval_ms, max_retries)
      holder ||= _gen_holder
      out = _output(lock_acquire(keys, holder: holder, ttl_ms: ttl_ms, wait: wait))
      return Lock.new(self, keys, holder, out["fencing_token"], out["lease_expires_ms"]) if out["acquired"]
      return nil unless wait # try_lock: held now -> fail fast

      deadline = _now_ms + max_wait_ms
      attempts = 0
      while max_retries.nil? || attempts < max_retries
        attempts += 1
        remaining = deadline - _now_ms
        break if remaining <= 0
        sleep([retry_interval_ms, remaining].min / 1000.0)
        lk = (lock_get(keys[0]) || {})["lock"] || {}
        if lk["holder"] == holder && !lk["fencing_token"].nil?
          return Lock.new(self, keys, holder, lk["fencing_token"], lk["lease_expires_ms"])
        end
      end
      nil
    end

    def _acquire_semaphore(key, limit, wait, ttl_ms, holder, max_wait_ms, retry_interval_ms, max_retries)
      holder ||= _gen_holder
      out = _output(semaphore_acquire(key, limit, holder: holder, ttl_ms: ttl_ms, wait: wait))
      return SemaphoreHandle.new(self, key, holder, out["fencing_token"], out["lease_expires_ms"]) if out["acquired"]
      return nil unless wait

      deadline = _now_ms + max_wait_ms
      attempts = 0
      while max_retries.nil? || attempts < max_retries
        attempts += 1
        remaining = deadline - _now_ms
        break if remaining <= 0
        sleep([retry_interval_ms, remaining].min / 1000.0)
        sem = (semaphore_get(key) || {})["semaphore"] || {}
        slot = (sem["holders"] || []).find { |h| h["holder"] == holder }
        if slot && !slot["fencing_token"].nil?
          return SemaphoreHandle.new(self, key, holder, slot["fencing_token"], slot["lease_expires_ms"])
        end
      end
      nil
    end

    def _now_ms
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i
    end

    def enc(s)
      URI.encode_www_form_component(s.to_s)
    end

    def request(method, path, body = nil, opts: {}, lock_acquire: false)
      max_retries = resolve_retries(opts)
      attempt = 0
      begin
        return request_once(method, path, body, opts: opts, lock_acquire: lock_acquire)
      rescue StandardError => e
        raise unless attempt < max_retries && retryable?(e)
        attempt += 1
        delay = resolve_retry_delay(opts)
        sleep delay if delay.positive?
        retry
      end
    end

    def request_once(method, path, body = nil, opts: {}, lock_acquire: false)
      uri = URI(@base + path)
      klass = {
        "GET" => Net::HTTP::Get, "PUT" => Net::HTTP::Put,
        "POST" => Net::HTTP::Post, "DELETE" => Net::HTTP::Delete
      }.fetch(method)
      req = klass.new(uri)
      if body
        req["content-type"] = "application/json"
        req.body = JSON.generate(body)
      end
      timeout = resolve_timeout(opts, lock_acquire)
      http_opts = { use_ssl: uri.scheme == "https" }
      if timeout
        http_opts[:open_timeout] = timeout
        http_opts[:read_timeout] = timeout
      end
      res = Net::HTTP.start(uri.host, uri.port, **http_opts) { |h| h.request(req) }
      data = res.body && !res.body.empty? ? JSON.parse(res.body) : nil
      raise Error.new(res.code.to_i, data) if res.code.to_i >= 300
      data
    end

    def resolve_timeout(opts, lock_acquire)
      return opts[:lock_request_timeout_ms] / 1000.0 if opts[:lock_request_timeout_ms]
      return opts[:request_timeout_ms] / 1000.0 if opts[:request_timeout_ms]
      return opts[:timeout_ms] / 1000.0 if opts[:timeout_ms]
      return opts[:lock_request_timeout] if opts[:lock_request_timeout]
      return opts[:request_timeout] if opts[:request_timeout]
      return opts[:timeout] if opts[:timeout]
      return @lock_request_timeout if lock_acquire && @lock_request_timeout
      @request_timeout
    end

    def resolve_retries(opts)
      [:max_retries, :retry_max, :retries].each do |key|
        return [opts[key].to_i, 0].max if opts[key]
      end
      [@retry_max.to_i, 0].max
    end

    def resolve_retry_delay(opts)
      return opts[:retry_delay_ms] / 1000.0 if opts[:retry_delay_ms]
      return opts[:retry_delay] if opts[:retry_delay]
      @retry_delay.to_f
    end

    def retryable?(error)
      return [408, 425, 429, 500, 502, 503, 504].include?(error.status) if error.is_a?(Error)
      error.is_a?(Timeout::Error) ||
        error.is_a?(Errno::ECONNRESET) ||
        error.is_a?(Errno::ECONNREFUSED) ||
        error.is_a?(SocketError)
    end
  end
end
