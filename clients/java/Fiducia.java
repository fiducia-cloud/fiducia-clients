// Fiducia HTTP client (Java, JDK 11+). Zero-dependency — java.net.http.
// Java has no stdlib JSON parser, so methods return the raw JSON response body
// (String); parse it with your JSON library of choice.
//
//   Fiducia c = new Fiducia("https://api.fiducia.cloud");
//   String lock = c.lockAcquire("orders/checkout", 30000L, true, 1);
//   c.lockRelease("orders/checkout", "worker-a", 7L);

package cloud.fiducia;

import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;

public class Fiducia {
    private final String base;
    private final HttpClient http = HttpClient.newHttpClient();
    public Duration requestTimeout = null;
    public Duration lockRequestTimeout = null;
    public int retryMax = 0;
    public Duration retryDelay = Duration.ZERO;

    public Fiducia(String baseUrl) {
        this.base = baseUrl.replaceAll("/+$", "");
    }

    public static class FiduciaException extends RuntimeException {
        public final int status;
        public final String body;
        public FiduciaException(int status, String body) {
            super("fiducia: HTTP " + status);
            this.status = status;
            this.body = body;
        }
    }

    public static class RequestOptions {
        public Duration timeout = null;
        public Duration requestTimeout = null;
        public Duration lockRequestTimeout = null;
        public int maxRetries = 0;
        public int retryMax = 0;
        public int retries = 0;
        public Duration retryDelay = Duration.ZERO;
    }

    private String request(String method, String path, String jsonBody) {
        return request(method, path, jsonBody, null, false);
    }

    private String request(String method, String path, String jsonBody, RequestOptions opts, boolean lockAcquire) {
        int retries = resolveRetries(opts);
        for (int attempt = 0; ; attempt++) {
            try {
                return requestOnce(method, path, jsonBody, opts, lockAcquire);
            } catch (RuntimeException e) {
                if (attempt >= retries || !retryable(e)) throw e;
                sleep(resolveRetryDelay(opts));
            }
        }
    }

    private String requestOnce(String method, String path, String jsonBody, RequestOptions opts, boolean lockAcquire) {
        HttpRequest.Builder b = HttpRequest.newBuilder(URI.create(base + path));
        Duration timeout = resolveTimeout(opts, lockAcquire);
        if (timeout != null) b.timeout(timeout);
        if (jsonBody != null) {
            b.header("content-type", "application/json")
             .method(method, HttpRequest.BodyPublishers.ofString(jsonBody));
        } else {
            b.method(method, HttpRequest.BodyPublishers.noBody());
        }
        try {
            HttpResponse<String> r = http.send(b.build(), HttpResponse.BodyHandlers.ofString());
            if (r.statusCode() >= 300) throw new FiduciaException(r.statusCode(), r.body());
            return r.body();
        } catch (java.io.IOException | InterruptedException e) {
            throw new RuntimeException(e);
        }
    }

    private Duration resolveTimeout(RequestOptions opts, boolean lockAcquire) {
        if (opts != null && opts.lockRequestTimeout != null) return opts.lockRequestTimeout;
        if (opts != null && opts.requestTimeout != null) return opts.requestTimeout;
        if (opts != null && opts.timeout != null) return opts.timeout;
        if (lockAcquire && lockRequestTimeout != null) return lockRequestTimeout;
        return requestTimeout;
    }

    private int resolveRetries(RequestOptions opts) {
        if (opts != null && opts.maxRetries > 0) return opts.maxRetries;
        if (opts != null && opts.retryMax > 0) return opts.retryMax;
        if (opts != null && opts.retries > 0) return opts.retries;
        return Math.max(retryMax, 0);
    }

    private Duration resolveRetryDelay(RequestOptions opts) {
        if (opts != null && opts.retryDelay != null && !opts.retryDelay.isZero()) return opts.retryDelay;
        return retryDelay == null ? Duration.ZERO : retryDelay;
    }

    private static boolean retryable(RuntimeException e) {
        if (e instanceof FiduciaException) {
            int status = ((FiduciaException) e).status;
            return status == 408 || status == 425 || status == 429 || status == 500 ||
                   status == 502 || status == 503 || status == 504;
        }
        return true;
    }

    private static void sleep(Duration delay) {
        if (delay == null || delay.isZero() || delay.isNegative()) return;
        try {
            Thread.sleep(delay.toMillis());
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new RuntimeException(e);
        }
    }

    private static String enc(String s) {
        return URLEncoder.encode(s, StandardCharsets.UTF_8).replace("+", "%20");
    }

    // Minimal JSON object builder for request bodies (String/Number/Boolean/null).
    private static String obj(Object... kv) {
        StringBuilder sb = new StringBuilder("{");
        for (int i = 0; i < kv.length; i += 2) {
            if (i > 0) sb.append(',');
            sb.append('"').append(kv[i]).append("\":");
            Object v = kv[i + 1];
            if (v == null) sb.append("null");
            else if (v instanceof String) sb.append('"').append(esc((String) v)).append('"');
            else sb.append(v); // Number / Boolean
        }
        return sb.append('}').toString();
    }

    private static String esc(String s) {
        return s.replace("\\", "\\\\").replace("\"", "\\\"");
    }

    // --- misc ---
    public String health() { return request("GET", "/healthz", null); }
    public String status() { return request("GET", "/v1/status", null); }

    // --- locks & semaphores ---
    public String lockAcquire(String key, Long ttlMs, boolean wait, int max) {
        return lockAcquire(key, ttlMs, wait, max, null);
    }
    public String lockAcquire(String key, Long ttlMs, boolean wait, int max, RequestOptions opts) {
        return lockAcquireWithWait(key, ttlMs, wait, max, opts);
    }
    public String tryLock(String key, Long ttlMs) {
        return lockAcquireWithWait(key, ttlMs, false, 1, null);
    }
    public String tryLock(String key, Long ttlMs, RequestOptions opts) {
        return lockAcquireWithWait(key, ttlMs, false, 1, opts);
    }
    public String tryLock(String key, Long ttlMs, int max) {
        return lockAcquireWithWait(key, ttlMs, false, max, null);
    }
    public String tryLock(String key, Long ttlMs, int max, RequestOptions opts) {
        return lockAcquireWithWait(key, ttlMs, false, max, opts);
    }
    public String mustLock(String key, Long ttlMs) {
        return lockAcquireWithWait(key, ttlMs, true, 1, null);
    }
    public String mustLock(String key, Long ttlMs, RequestOptions opts) {
        return lockAcquireWithWait(key, ttlMs, true, 1, opts);
    }
    public String mustLock(String key, Long ttlMs, int max) {
        return lockAcquireWithWait(key, ttlMs, true, max, null);
    }
    public String mustLock(String key, Long ttlMs, int max, RequestOptions opts) {
        return lockAcquireWithWait(key, ttlMs, true, max, opts);
    }
    public String lock(String key, Long ttlMs) {
        return mustLock(key, ttlMs);
    }
    public String lock(String key, Long ttlMs, RequestOptions opts) {
        return mustLock(key, ttlMs, 1, opts);
    }
    public String lock(String key, Long ttlMs, int max) {
        return mustLock(key, ttlMs, max);
    }
    public String lock(String key, Long ttlMs, int max, RequestOptions opts) {
        return mustLock(key, ttlMs, max, opts);
    }
    private String lockAcquireWithWait(String key, Long ttlMs, boolean wait, int max, RequestOptions opts) {
        return request("POST", "/v1/locks/acquire",
            obj("key", key, "ttl_ms", ttlMs, "wait", wait, "max", max), opts, true);
    }
    public String semaphoreAcquire(String key, Long ttlMs, boolean wait, int max) {
        return semaphoreAcquire(key, ttlMs, wait, max, null);
    }
    public String semaphoreAcquire(String key, Long ttlMs, boolean wait, int max, RequestOptions opts) {
        return semaphoreAcquireWithWait(key, ttlMs, wait, max, opts);
    }
    public String trySemaphore(String key, Long ttlMs, int max) {
        return semaphoreAcquireWithWait(key, ttlMs, false, max, null);
    }
    public String trySemaphore(String key, Long ttlMs, int max, RequestOptions opts) {
        return semaphoreAcquireWithWait(key, ttlMs, false, max, opts);
    }
    public String mustSemaphore(String key, Long ttlMs, int max) {
        return semaphoreAcquireWithWait(key, ttlMs, true, max, null);
    }
    public String mustSemaphore(String key, Long ttlMs, int max, RequestOptions opts) {
        return semaphoreAcquireWithWait(key, ttlMs, true, max, opts);
    }
    public String semaphore(String key, Long ttlMs, int max) {
        return mustSemaphore(key, ttlMs, max);
    }
    public String semaphore(String key, Long ttlMs, int max, RequestOptions opts) {
        return mustSemaphore(key, ttlMs, max, opts);
    }
    private String semaphoreAcquireWithWait(String key, Long ttlMs, boolean wait, int max, RequestOptions opts) {
        return request("POST", "/v1/semaphores/acquire",
            obj("key", key, "ttl_ms", ttlMs, "wait", wait, "limit", Math.max(max, 2)), opts, true);
    }
    public String lockRelease(String key, String holder, long fencingToken) {
        return request("POST", "/v1/locks/release", obj("holder", holder, "fencing_token", fencingToken));
    }
    public String semaphoreRelease(String key, String holder, long fencingToken) {
        return request("POST", "/v1/semaphores/release", obj("key", key, "holder", holder, "fencing_token", fencingToken));
    }

    // --- reader-writer locks ---
    public String rwAcquireRead(String key, Long ttlMs, boolean wait) {
        return request("POST", "/v1/rw/" + enc(key) + "/read", obj("ttl_ms", ttlMs, "wait", wait));
    }
    public String rwEndRead(String key, String lockId) {
        return request("POST", "/v1/rw/" + enc(key) + "/read/end", obj("lock_id", lockId));
    }
    public String rwAcquireWrite(String key, Long ttlMs, boolean wait) {
        return request("POST", "/v1/rw/" + enc(key) + "/write", obj("ttl_ms", ttlMs, "wait", wait));
    }
    public String rwEndWrite(String key, String lockId) {
        return request("POST", "/v1/rw/" + enc(key) + "/write/end", obj("lock_id", lockId));
    }

    // --- config KV ---
    public String kvGet(String key) { return request("GET", "/v1/kv?key=" + enc(key), null); }
    public String kvPut(String key, String value, Long ttlMs) {
        return request("PUT", "/v1/kv?key=" + enc(key), obj("value", value, "ttl_ms", ttlMs));
    }
    public String kvDelete(String key) { return request("DELETE", "/v1/kv?key=" + enc(key), null); }
    public String kvList(String prefix) { return request("GET", "/v1/kv?prefix=" + enc(prefix), null); }

    // --- leader election ---
    public String electionCampaign(String name, String candidate, long ttlMs) {
        return request("POST", "/v1/elections/" + enc(name) + "/campaign", obj("candidate", candidate, "ttl_ms", ttlMs));
    }
    public String electionRenew(String name, String candidate, long fencingToken) {
        return request("POST", "/v1/elections/" + enc(name) + "/renew", obj("candidate", candidate, "fencing_token", fencingToken));
    }
    public String electionResign(String name, String candidate, long fencingToken) {
        return request("POST", "/v1/elections/" + enc(name) + "/resign", obj("candidate", candidate, "fencing_token", fencingToken));
    }
    public String electionGet(String name) { return request("GET", "/v1/elections/" + enc(name), null); }

    // --- service discovery ---
    public String serviceRegister(String service, String instanceId, String address, long ttlMs) {
        return request("PUT", "/v1/services/" + enc(service) + "/instances/" + enc(instanceId), obj("address", address, "ttl_ms", ttlMs));
    }
    public String serviceHeartbeat(String service, String instanceId) {
        return request("POST", "/v1/services/" + enc(service) + "/instances/" + enc(instanceId) + "/heartbeat", null);
    }
    public String serviceDeregister(String service, String instanceId) {
        return request("DELETE", "/v1/services/" + enc(service) + "/instances/" + enc(instanceId), null);
    }
    public String serviceInstances(String service) { return request("GET", "/v1/services/" + enc(service), null); }
    public String serviceList() { return request("GET", "/v1/services", null); }
}
