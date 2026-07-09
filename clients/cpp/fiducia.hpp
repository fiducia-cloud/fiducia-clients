// Fiducia HTTP client (C++17, header-only). Transport: libcurl. JSON: nlohmann/json.
// Implements PROTOCOL.md.
//
// Dependencies (declare them in your build):
//   * libcurl        -- link with -lcurl                 (HTTP transport)
//   * nlohmann/json  -- header-only, <nlohmann/json.hpp>  (JSON encode/decode)
//
//   #include "fiducia.hpp"
//   fiducia::Client c("https://api.fiducia.cloud");
//   auto lock = c.lock_acquire("orders/checkout", std::nullopt, 30000);
//   c.lock_release("orders/checkout", "worker-a",
//                  lock["result"]["output"]["fencing_token"].get<std::int64_t>());

#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include <curl/curl.h>
#include <nlohmann/json.hpp>

namespace fiducia {

using json = nlohmann::json;

// Thrown on any HTTP response with status >= 300. `body` is the parsed JSON
// response (or the raw string / null when the body was not JSON / was empty).
struct Error : std::runtime_error {
    int status;
    json body;
    Error(int status_, json body_)
        : std::runtime_error("fiducia: HTTP " + std::to_string(status_)),
          status(status_),
          body(std::move(body_)) {}
};

namespace detail {

// libcurl global state is initialized exactly once, the first time any Client
// is constructed (thread-safe via C++11 static-local initialization). We
// deliberately skip curl_global_cleanup(): it is optional and is unsafe to run
// while other threads may still be using libcurl.
inline void global_init() {
    static const bool initialized = [] {
        return curl_global_init(CURL_GLOBAL_DEFAULT) == CURLE_OK;
    }();
    (void)initialized;
}

// RAII holder for a libcurl easy handle: curl_easy_cleanup runs on every exit
// path (normal return OR exception), so the handle never leaks even if a later
// step throws (e.g. json::dump on invalid UTF-8) before the request completes.
class EasyHandle {
public:
    EasyHandle() : h_(curl_easy_init()) {}
    ~EasyHandle() { if (h_) curl_easy_cleanup(h_); }
    EasyHandle(const EasyHandle&) = delete;
    EasyHandle& operator=(const EasyHandle&) = delete;
    CURL* get() const { return h_; }
    explicit operator bool() const { return h_ != nullptr; }

private:
    CURL* h_;
};

// RAII holder for a libcurl header list; curl_slist_free_all runs on every exit
// path. Kept in scope for the whole transfer, then freed automatically.
class HeaderList {
public:
    HeaderList() = default;
    ~HeaderList() { if (list_) curl_slist_free_all(list_); }
    HeaderList(const HeaderList&) = delete;
    HeaderList& operator=(const HeaderList&) = delete;
    void append(const char* header) { list_ = curl_slist_append(list_, header); }
    curl_slist* get() const { return list_; }

private:
    curl_slist* list_ = nullptr;
};

}  // namespace detail

// A thin HTTP wrapper over the fiducia.cloud contract. Construct it with a base
// URL; every method performs one request and returns the parsed JSON body (an
// empty body decodes to null). See PROTOCOL.md for the full method surface.
class Client {
public:
    // base_url has any trailing slashes trimmed. request_timeout_ms == 0 means
    // no client-side timeout (libcurl default).
    explicit Client(std::string base_url, long request_timeout_ms = 0)
        : base_(trim_trailing_slash(std::move(base_url))),
          request_timeout_ms_(request_timeout_ms) {
        detail::global_init();
    }

    void set_request_timeout_ms(long ms) { request_timeout_ms_ = ms; }
    long request_timeout_ms() const { return request_timeout_ms_; }
    const std::string& base_url() const { return base_; }

    // --- misc ---
    json health() { return request("GET", "/healthz"); }
    json status() { return request("GET", "/v1/status"); }

    // --- locks ---
    json lock_get(const std::string& key) {
        return request("GET", "/v1/locks?key=" + enc(key));
    }
    json lock_acquire(const std::string& key,
                      std::optional<std::string> holder = std::nullopt,
                      std::optional<std::int64_t> ttl_ms = std::nullopt,
                      bool wait = true) {
        json body = json::object();
        body["key"] = key;
        body["wait"] = wait;
        if (holder) body["holder"] = *holder;
        if (ttl_ms) body["ttl_ms"] = *ttl_ms;
        return request("POST", "/v1/locks/acquire", body);
    }
    // Multi-key UNION lock: all-or-nothing across the whole set.
    json lock_acquire_many(const std::vector<std::string>& keys,
                           std::optional<std::string> holder = std::nullopt,
                           std::optional<std::int64_t> ttl_ms = std::nullopt,
                           bool wait = true) {
        json body = json::object();
        body["keys"] = keys;
        body["wait"] = wait;
        if (holder) body["holder"] = *holder;
        if (ttl_ms) body["ttl_ms"] = *ttl_ms;
        return request("POST", "/v1/locks/acquire", body);
    }
    json try_lock(const std::string& key,
                  std::optional<std::string> holder = std::nullopt,
                  std::optional<std::int64_t> ttl_ms = std::nullopt) {
        return lock_acquire(key, std::move(holder), ttl_ms, false);
    }
    json must_lock(const std::string& key,
                   std::optional<std::string> holder = std::nullopt,
                   std::optional<std::int64_t> ttl_ms = std::nullopt) {
        return lock_acquire(key, std::move(holder), ttl_ms, true);
    }
    json lock(const std::string& key,
              std::optional<std::string> holder = std::nullopt,
              std::optional<std::int64_t> ttl_ms = std::nullopt) {
        return must_lock(key, std::move(holder), ttl_ms);
    }
    // `key` is accepted for call-site symmetry but is NOT sent in the body.
    json lock_release(const std::string& key, const std::string& holder,
                      std::int64_t fencing_token) {
        (void)key;
        json body = json::object();
        body["holder"] = holder;
        body["fencing_token"] = fencing_token;
        return request("POST", "/v1/locks/release", body);
    }

    // --- semaphores ---
    json semaphore_get(const std::string& key) {
        return request("GET", "/v1/semaphores?key=" + enc(key));
    }
    json semaphore_acquire(const std::string& key, std::int64_t limit,
                           std::optional<std::string> holder = std::nullopt,
                           std::optional<std::int64_t> ttl_ms = std::nullopt,
                           bool wait = true) {
        json body = json::object();
        body["key"] = key;
        body["limit"] = limit;
        body["wait"] = wait;
        if (holder) body["holder"] = *holder;
        if (ttl_ms) body["ttl_ms"] = *ttl_ms;
        return request("POST", "/v1/semaphores/acquire", body);
    }
    json try_semaphore(const std::string& key, std::int64_t limit,
                       std::optional<std::string> holder = std::nullopt,
                       std::optional<std::int64_t> ttl_ms = std::nullopt) {
        return semaphore_acquire(key, limit, std::move(holder), ttl_ms, false);
    }
    json must_semaphore(const std::string& key, std::int64_t limit,
                        std::optional<std::string> holder = std::nullopt,
                        std::optional<std::int64_t> ttl_ms = std::nullopt) {
        return semaphore_acquire(key, limit, std::move(holder), ttl_ms, true);
    }
    json semaphore(const std::string& key, std::int64_t limit,
                   std::optional<std::string> holder = std::nullopt,
                   std::optional<std::int64_t> ttl_ms = std::nullopt) {
        return must_semaphore(key, limit, std::move(holder), ttl_ms);
    }
    json semaphore_release(const std::string& key, const std::string& holder,
                           std::int64_t fencing_token) {
        json body = json::object();
        body["key"] = key;
        body["holder"] = holder;
        body["fencing_token"] = fencing_token;
        return request("POST", "/v1/semaphores/release", body);
    }

    // --- idempotency ---
    json idempotency_get(const std::string& key) {
        return request("GET", "/v1/idempotency?key=" + enc(key));
    }
    // metadata is an arbitrary JSON object; pass null (default) to omit it.
    json idempotency_claim(const std::string& key,
                           std::optional<std::string> owner = std::nullopt,
                           std::optional<std::int64_t> ttl_ms = std::nullopt,
                           std::optional<std::string> ttl = std::nullopt,
                           json metadata = nullptr) {
        json body = json::object();
        body["key"] = key;
        if (owner) body["owner"] = *owner;
        if (ttl_ms) body["ttl_ms"] = *ttl_ms;
        if (ttl) body["ttl"] = *ttl;
        if (!metadata.is_null()) body["metadata"] = std::move(metadata);
        return request("POST", "/v1/idempotency/claim", body);
    }
    // result is an arbitrary JSON object; pass null (default) to omit it.
    json idempotency_complete(const std::string& key, const std::string& owner,
                              std::int64_t fencing_token, json result = nullptr) {
        json body = json::object();
        body["key"] = key;
        body["owner"] = owner;
        body["fencing_token"] = fencing_token;
        if (!result.is_null()) body["result"] = std::move(result);
        return request("POST", "/v1/idempotency/complete", body);
    }

    // --- reader-writer locks ---
    json rw_acquire_read(const std::string& key,
                         std::optional<std::int64_t> ttl_ms = std::nullopt,
                         bool wait = true) {
        json body = json::object();
        body["wait"] = wait;
        if (ttl_ms) body["ttl_ms"] = *ttl_ms;
        return request("POST", "/v1/rw/" + enc(key) + "/read", body);
    }
    json rw_end_read(const std::string& key, const std::string& lock_id) {
        json body = json::object();
        body["lock_id"] = lock_id;
        return request("POST", "/v1/rw/" + enc(key) + "/read/end", body);
    }
    json rw_acquire_write(const std::string& key,
                          std::optional<std::int64_t> ttl_ms = std::nullopt,
                          bool wait = true) {
        json body = json::object();
        body["wait"] = wait;
        if (ttl_ms) body["ttl_ms"] = *ttl_ms;
        return request("POST", "/v1/rw/" + enc(key) + "/write", body);
    }
    json rw_end_write(const std::string& key, const std::string& lock_id) {
        json body = json::object();
        body["lock_id"] = lock_id;
        return request("POST", "/v1/rw/" + enc(key) + "/write/end", body);
    }

    // --- config KV ---
    json kv_get(const std::string& key) {
        return request("GET", "/v1/kv?key=" + enc(key));
    }
    // prev_revision is a compare-and-swap guard (0 = must-not-exist); pass it
    // explicitly to enable CAS, or std::nullopt to write unconditionally.
    json kv_put(const std::string& key, const std::string& value,
                std::optional<std::int64_t> ttl_ms = std::nullopt,
                std::optional<std::int64_t> prev_revision = std::nullopt) {
        json body = json::object();
        body["value"] = value;
        if (ttl_ms) body["ttl_ms"] = *ttl_ms;
        if (prev_revision) body["prev_revision"] = *prev_revision;
        return request("PUT", "/v1/kv?key=" + enc(key), body);
    }
    json kv_delete(const std::string& key) {
        return request("DELETE", "/v1/kv?key=" + enc(key));
    }
    json kv_list(const std::string& prefix) {
        return request("GET", "/v1/kv?prefix=" + enc(prefix));
    }

    // --- rate limiting ---
    json rate_limit_get(const std::string& tenant, const std::string& key) {
        return request("GET", "/v1/rate-limit/" + enc(tenant) + "/" + enc(key));
    }
    json rate_limit_check(const std::string& tenant, const std::string& key,
                          const std::string& algorithm, std::int64_t limit,
                          std::int64_t window_ms,
                          std::optional<double> refill_per_second = std::nullopt,
                          std::optional<std::int64_t> cost = std::nullopt) {
        json body = json::object();
        body["algorithm"] = algorithm;
        body["limit"] = limit;
        body["window_ms"] = window_ms;
        if (refill_per_second) body["refill_per_second"] = *refill_per_second;
        if (cost) body["cost"] = *cost;
        return request(
            "POST", "/v1/rate-limit/" + enc(tenant) + "/" + enc(key) + "/check", body);
    }

    // --- cron & scheduling ---
    json schedule_get(const std::string& name) {
        return request("GET", "/v1/cron/schedules/" + enc(name));
    }
    // target is an arbitrary JSON object, e.g. {"kind":"webhook","url":"..."}.
    json schedule_upsert(const std::string& name, const json& target,
                         std::optional<std::string> cron = std::nullopt,
                         std::optional<std::int64_t> one_shot_at_ms = std::nullopt,
                         std::optional<std::string> delivery = std::nullopt,
                         std::optional<std::int64_t> max_retries = std::nullopt) {
        json body = json::object();
        body["target"] = target;
        if (cron) body["cron"] = *cron;
        if (one_shot_at_ms) body["one_shot_at_ms"] = *one_shot_at_ms;
        if (delivery) body["delivery"] = *delivery;
        if (max_retries) body["max_retries"] = *max_retries;
        return request("PUT", "/v1/cron/schedules/" + enc(name), body);
    }
    json schedule_record_run(const std::string& name, const std::string& fire_id,
                             std::optional<std::int64_t> fired_at_ms = std::nullopt) {
        json body = json::object();
        body["fire_id"] = fire_id;
        if (fired_at_ms) body["fired_at_ms"] = *fired_at_ms;
        return request("POST", "/v1/cron/schedules/" + enc(name) + "/runs", body);
    }
    json schedule_history(const std::string& name) {
        return request("GET", "/v1/cron/schedules/" + enc(name) + "/history");
    }

    // --- leader election ---
    json election_get(const std::string& name) {
        return request("GET", "/v1/elections/" + enc(name));
    }
    json election_campaign(const std::string& name, const std::string& candidate,
                           std::int64_t ttl_ms, json metadata = nullptr) {
        json body = json::object();
        body["candidate"] = candidate;
        body["ttl_ms"] = ttl_ms;
        if (!metadata.is_null()) body["metadata"] = std::move(metadata);
        return request("POST", "/v1/elections/" + enc(name) + "/campaign", body);
    }
    json election_renew(const std::string& name, const std::string& candidate,
                        std::int64_t fencing_token) {
        json body = json::object();
        body["candidate"] = candidate;
        body["fencing_token"] = fencing_token;
        return request("POST", "/v1/elections/" + enc(name) + "/renew", body);
    }
    json election_resign(const std::string& name, const std::string& candidate,
                         std::int64_t fencing_token) {
        json body = json::object();
        body["candidate"] = candidate;
        body["fencing_token"] = fencing_token;
        return request("POST", "/v1/elections/" + enc(name) + "/resign", body);
    }

    // --- service discovery ---
    json service_instances(const std::string& service) {
        return request("GET", "/v1/services/" + enc(service));
    }
    json service_register(const std::string& service, const std::string& instance_id,
                          const std::string& address, std::int64_t ttl_ms,
                          json metadata = nullptr) {
        json body = json::object();
        body["address"] = address;
        body["ttl_ms"] = ttl_ms;
        if (!metadata.is_null()) body["metadata"] = std::move(metadata);
        return request(
            "PUT", "/v1/services/" + enc(service) + "/instances/" + enc(instance_id),
            body);
    }
    json service_heartbeat(const std::string& service, const std::string& instance_id,
                           std::optional<std::int64_t> ttl_ms = std::nullopt) {
        json body = json::object();
        if (ttl_ms) body["ttl_ms"] = *ttl_ms;
        return request("POST",
                       "/v1/services/" + enc(service) + "/instances/" +
                           enc(instance_id) + "/heartbeat",
                       body);
    }
    json service_deregister(const std::string& service,
                            const std::string& instance_id) {
        return request(
            "DELETE", "/v1/services/" + enc(service) + "/instances/" + enc(instance_id));
    }
    json service_list() { return request("GET", "/v1/services"); }

private:
    std::string base_;
    long request_timeout_ms_;

    static std::string trim_trailing_slash(std::string s) {
        while (!s.empty() && s.back() == '/') s.pop_back();
        return s;
    }

    static std::size_t write_cb(char* ptr, std::size_t size, std::size_t nmemb,
                                void* userdata) {
        std::size_t n = size * nmemb;
        auto* out = static_cast<std::string*>(userdata);
        // Never let a C++ exception unwind through libcurl's C stack (UB). On
        // allocation failure, signal a short write so curl aborts the transfer.
        try {
            out->append(ptr, n);
        } catch (...) {
            return 0;
        }
        return n;
    }

    // URL-encode one path/query segment (RFC 3986) via libcurl.
    static std::string enc(const std::string& s) {
        detail::global_init();
        detail::EasyHandle easy;  // freed on every return path (incl. throws)
        char* escaped =
            curl_easy_escape(easy.get(), s.c_str(), static_cast<int>(s.size()));
        std::string out = escaped ? std::string(escaped) : std::string();
        if (escaped) curl_free(escaped);
        return out;
    }

    json request(const std::string& method, const std::string& path,
                 std::optional<json> body = std::nullopt) {
        CURL* curl = curl_easy_init();
        if (!curl) throw std::runtime_error("fiducia: curl_easy_init failed");

        std::string url = base_ + path;
        std::string response;
        std::string payload;
        struct curl_slist* headers = nullptr;

        curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
        curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, method.c_str());
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, &Client::write_cb);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response);
        curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
        if (request_timeout_ms_ > 0)
            curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, request_timeout_ms_);

        if (body) {
            payload = body->dump();
            headers = curl_slist_append(headers, "Content-Type: application/json");
            curl_easy_setopt(curl, CURLOPT_POSTFIELDS, payload.c_str());
            curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE,
                             static_cast<long>(payload.size()));
        }
        if (headers) curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);

        CURLcode rc = curl_easy_perform(curl);
        long status = 0;
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
        if (headers) curl_slist_free_all(headers);
        curl_easy_cleanup(curl);

        if (rc != CURLE_OK)
            throw std::runtime_error(std::string("fiducia: request failed: ") +
                                     curl_easy_strerror(rc));

        json data = nullptr;
        if (!response.empty()) {
            data = json::parse(response, nullptr, /*allow_exceptions=*/false);
            if (data.is_discarded()) data = json(response);  // non-JSON body
        }
        if (status >= 300) throw Error(static_cast<int>(status), data);
        return data;
    }
};

}  // namespace fiducia
