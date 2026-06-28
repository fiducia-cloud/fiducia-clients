// Fiducia HTTP client (Java, JDK 11+). Zero-dependency — java.net.http.
// Java has no stdlib JSON parser, so methods return the raw JSON response body
// (String); parse it with your JSON library of choice.
//
//   Fiducia c = new Fiducia("https://api.fiducia.cloud");
//   String lock = c.lockAcquire("orders/checkout", 30000L, true, 1);
//   c.lockRelease("orders/checkout", "<lock_id from the JSON>");

package cloud.fiducia;

import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

public class Fiducia {
    private final String base;
    private final HttpClient http = HttpClient.newHttpClient();

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

    private String request(String method, String path, String jsonBody) {
        HttpRequest.Builder b = HttpRequest.newBuilder(URI.create(base + path));
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
            else if (v instanceof List) {
                sb.append('[');
                List<?> list = (List<?>) v;
                for (int j = 0; j < list.size(); j++) {
                    if (j > 0) sb.append(',');
                    sb.append('"').append(esc(String.valueOf(list.get(j)))).append('"');
                }
                sb.append(']');
            } else sb.append(v); // Number / Boolean
        }
        return sb.append('}').toString();
    }

    private static String esc(String s) {
        return s.replace("\\", "\\\\").replace("\"", "\\\"");
    }

    // --- misc ---
    public String health() { return request("GET", "/healthz", null); }
    public String status() { return request("GET", "/v1/status", null); }

    // --- locks (current protocol: holder + fencing_token, keys in the body) ---
    public String lockGet(String key) { return request("GET", "/v1/locks?key=" + enc(key), null); }
    public String lockAcquire(List<String> keys, String holder, Long ttlMs, boolean wait) {
        return request("POST", "/v1/locks/acquire", obj("keys", keys, "holder", holder, "ttl_ms", ttlMs, "wait", wait));
    }
    public String lockRelease(String holder, long fencingToken) {
        return request("POST", "/v1/locks/release", obj("holder", holder, "fencing_token", fencingToken));
    }

    // --- semaphores ---
    public String semaphoreGet(String key) { return request("GET", "/v1/semaphores?key=" + enc(key), null); }
    public String semaphoreAcquire(String key, int limit, String holder, Long ttlMs, boolean wait) {
        return request("POST", "/v1/semaphores/acquire", obj("key", key, "limit", limit, "holder", holder, "ttl_ms", ttlMs, "wait", wait));
    }
    public String semaphoreRelease(String key, String holder, long fencingToken) {
        return request("POST", "/v1/semaphores/release", obj("key", key, "holder", holder, "fencing_token", fencingToken));
    }

    // --- high-level blocking / try acquisition (live-mutex style) ---

    /** tryLock: wait:false — returns a Lock if free now, else null. */
    public Lock tryLock(String key) { return tryLock(key, 60_000L); }
    public Lock tryLock(String key, long ttlMs) {
        return acquireLock(Arrays.asList(key), false, ttlMs, null, 0, 0, -1);
    }

    /** lock / mustLock: wait:true — block until acquired, the budget elapses
     *  (LockTimeoutException), or the server errors. */
    public Lock lock(String key) { return lock(key, 60_000L, 30_000, 250, -1); }
    public Lock lock(String key, long ttlMs, int maxWaitMs, int retryIntervalMs, int maxRetries) {
        Lock l = acquireLock(Arrays.asList(key), true, ttlMs, null, maxWaitMs, retryIntervalMs, maxRetries);
        if (l == null) throw new LockTimeoutException(Arrays.asList(key), maxWaitMs);
        return l;
    }
    public Lock mustLock(String key) { return lock(key); }
    public Lock mustLock(String key, long ttlMs, int maxWaitMs, int retryIntervalMs, int maxRetries) {
        return lock(key, ttlMs, maxWaitMs, retryIntervalMs, maxRetries);
    }

    /** trySemaphore / acquireSemaphore — the same pair for counting semaphores. */
    public SemaphoreHandle trySemaphore(String key, int limit) { return trySemaphore(key, limit, 60_000L); }
    public SemaphoreHandle trySemaphore(String key, int limit, long ttlMs) {
        return acquireSemaphore(key, limit, false, ttlMs, 0, 0, -1);
    }
    public SemaphoreHandle acquireSemaphore(String key, int limit) {
        return acquireSemaphore(key, limit, 60_000L, 30_000, 250, -1);
    }
    public SemaphoreHandle acquireSemaphore(String key, int limit, long ttlMs, int maxWaitMs, int retryIntervalMs, int maxRetries) {
        SemaphoreHandle h = acquireSemaphore(key, limit, true, ttlMs, maxWaitMs, retryIntervalMs, maxRetries);
        if (h == null) throw new LockTimeoutException(Arrays.asList(key), maxWaitMs);
        return h;
    }

    private Lock acquireLock(List<String> keys, boolean wait, long ttlMs, String holder,
                             int maxWaitMs, int retryIntervalMs, int maxRetries) {
        if (holder == null) holder = genHolder();
        Map<String, Object> out = output(lockAcquire(keys, holder, ttlMs, wait));
        if (asBool(out.get("acquired"))) {
            return new Lock(this, keys, holder, asLong(out.get("fencing_token")), asLongOrNull(out.get("lease_expires_ms")));
        }
        if (!wait) return null; // tryLock: held now -> fail fast
        long deadline = nowMs() + maxWaitMs;
        for (int attempt = 0; maxRetries < 0 || attempt < maxRetries; attempt++) {
            long remaining = deadline - nowMs();
            if (remaining <= 0) break;
            sleep(Math.min(retryIntervalMs, remaining));
            Map<String, Object> lock = asMap(asMap(Json.parse(lockGet(keys.get(0)))).get("lock"));
            if (holder.equals(asStr(lock.get("holder"))) && lock.get("fencing_token") != null) {
                return new Lock(this, keys, holder, asLong(lock.get("fencing_token")), asLongOrNull(lock.get("lease_expires_ms")));
            }
        }
        return null;
    }

    @SuppressWarnings("unchecked")
    private SemaphoreHandle acquireSemaphore(String key, int limit, boolean wait, long ttlMs,
                                             int maxWaitMs, int retryIntervalMs, int maxRetries) {
        String holder = genHolder();
        Map<String, Object> out = output(semaphoreAcquire(key, limit, holder, ttlMs, wait));
        if (asBool(out.get("acquired"))) {
            return new SemaphoreHandle(this, key, holder, asLong(out.get("fencing_token")), asLongOrNull(out.get("lease_expires_ms")));
        }
        if (!wait) return null;
        long deadline = nowMs() + maxWaitMs;
        for (int attempt = 0; maxRetries < 0 || attempt < maxRetries; attempt++) {
            long remaining = deadline - nowMs();
            if (remaining <= 0) break;
            sleep(Math.min(retryIntervalMs, remaining));
            Object holders = asMap(asMap(Json.parse(semaphoreGet(key))).get("semaphore")).get("holders");
            if (holders instanceof List) {
                for (Object o : (List<Object>) holders) {
                    Map<String, Object> slot = asMap(o);
                    if (holder.equals(asStr(slot.get("holder"))) && slot.get("fencing_token") != null) {
                        return new SemaphoreHandle(this, key, holder, asLong(slot.get("fencing_token")), asLongOrNull(slot.get("lease_expires_ms")));
                    }
                }
            }
        }
        return null;
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
    public String kvGet(String key) { return request("GET", "/v1/kv/" + enc(key), null); }
    public String kvPut(String key, String value, Long ttlMs) {
        return request("PUT", "/v1/kv/" + enc(key), obj("value", value, "ttl_ms", ttlMs));
    }
    public String kvDelete(String key) { return request("DELETE", "/v1/kv/" + enc(key), null); }
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
