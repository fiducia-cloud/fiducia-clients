# Fiducia HTTP client (Ruby). Zero-dependency — stdlib net/http + json.
# Implements PROTOCOL.md.
#
#   require_relative "fiducia"
#   c = Fiducia::Client.new("https://api.fiducia.cloud")
#   lock = c.lock_acquire("orders/checkout", ttl_ms: 30000)
#   c.lock_release("orders/checkout", lock["result"]["lock_id"])

require "net/http"
require "json"
require "uri"

module Fiducia
  class Error < StandardError
    attr_reader :status, :body
    def initialize(status, body)
      super("fiducia: HTTP #{status}")
      @status = status
      @body = body
    end
  end

  class Client
    def initialize(base_url)
      @base = base_url.sub(%r{/+\z}, "")
    end

    # --- misc ---
    def health; request("GET", "/healthz"); end
    def status; request("GET", "/v1/status"); end

    # --- locks & semaphores ---
    def lock_acquire(key, ttl_ms: nil, wait: true, max: 1)
      request("POST", "/v1/locks/#{enc key}/acquire", { ttl_ms: ttl_ms, wait: wait, max: max })
    end
    def lock_release(key, lock_id)
      request("POST", "/v1/locks/#{enc key}/release", { lock_id: lock_id })
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
    def kv_get(key); request("GET", "/v1/kv/#{enc key}"); end
    def kv_put(key, value, ttl_ms: nil)
      request("PUT", "/v1/kv/#{enc key}", { value: value, ttl_ms: ttl_ms })
    end
    def kv_delete(key); request("DELETE", "/v1/kv/#{enc key}"); end
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

    def enc(s)
      URI.encode_www_form_component(s.to_s)
    end

    def request(method, path, body = nil)
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
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |h| h.request(req) }
      data = res.body && !res.body.empty? ? JSON.parse(res.body) : nil
      raise Error.new(res.code.to_i, data) if res.code.to_i >= 300
      data
    end
  end
end
