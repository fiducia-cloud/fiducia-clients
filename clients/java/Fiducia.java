// Fiducia HTTP client (Java, JDK 11+). Zero-dependency — java.net.http + a tiny
// built-in JSON parser/serializer (no third-party JSON library needed).
//
// Requests are sent as JSON; responses are parsed into Map / List / String /
// Double / Boolean / null. Every endpoint returns a Map<String,Object>:
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
             .method(method, HttpRequest.BodyPublishers.ofString(Json.stringify(body)));
        } else {
            b.method(method, HttpRequest.BodyPublishers.noBody());
        }
        try {
            HttpResponse<String> r = http.send(b.build(), HttpResponse.BodyHandlers.ofString());
            if (r.statusCode() >= 300) throw new FiduciaException(r.statusCode(), r.body());
            return asMap(Json.parse(r.body()));
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

    // Build a JSON request body as an ordered map of key/value pairs.
    private static Map<String, Object> body(Object... kv) {
        Map<String, Object> m = new LinkedHashMap<>();
        for (int i = 0; i < kv.length; i += 2) m.put((String) kv[i], kv[i + 1]);
        return m;
    }

    // --- misc ---
    public Map<String, Object> health() { return request("GET", "/healthz", null); }
    public Map<String, Object> status() { return request("GET", "/v1/status", null); }

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
    public Map<String, Object> rwAcquireRead(String key, Long ttlMs, boolean wait) {
        return request("POST", "/v1/rw/" + enc(key) + "/read", body("ttl_ms", ttlMs, "wait", wait));
    }
    public Map<String, Object> rwEndRead(String key, String lockId) {
        return request("POST", "/v1/rw/" + enc(key) + "/read/end", body("lock_id", lockId));
    }
    public Map<String, Object> rwAcquireWrite(String key, Long ttlMs, boolean wait) {
        return request("POST", "/v1/rw/" + enc(key) + "/write", body("ttl_ms", ttlMs, "wait", wait));
    }
    public Map<String, Object> rwEndWrite(String key, String lockId) {
        return request("POST", "/v1/rw/" + enc(key) + "/write/end", body("lock_id", lockId));
    }

    // --- config KV ---
    public String kvGet(String key) { return request("GET", "/v1/kv?key=" + enc(key), null); }
    public String kvPut(String key, String value, Long ttlMs) {
        return request("PUT", "/v1/kv?key=" + enc(key), obj("value", value, "ttl_ms", ttlMs));
    }
    public String kvDelete(String key) { return request("DELETE", "/v1/kv?key=" + enc(key), null); }
    public String kvList(String prefix) { return request("GET", "/v1/kv?prefix=" + enc(prefix), null); }

    // --- leader election ---
    public Map<String, Object> electionCampaign(String name, String candidate, long ttlMs) {
        return request("POST", "/v1/elections/" + enc(name) + "/campaign", body("candidate", candidate, "ttl_ms", ttlMs));
    }
    public Map<String, Object> electionRenew(String name, String candidate, long fencingToken) {
        return request("POST", "/v1/elections/" + enc(name) + "/renew", body("candidate", candidate, "fencing_token", fencingToken));
    }
    public Map<String, Object> electionResign(String name, String candidate, long fencingToken) {
        return request("POST", "/v1/elections/" + enc(name) + "/resign", body("candidate", candidate, "fencing_token", fencingToken));
    }
    public Map<String, Object> electionGet(String name) { return request("GET", "/v1/elections/" + enc(name), null); }

    // --- service discovery ---
    public Map<String, Object> serviceRegister(String service, String instanceId, String address, long ttlMs) {
        return request("PUT", "/v1/services/" + enc(service) + "/instances/" + enc(instanceId), body("address", address, "ttl_ms", ttlMs));
    }
    public Map<String, Object> serviceHeartbeat(String service, String instanceId) {
        return request("POST", "/v1/services/" + enc(service) + "/instances/" + enc(instanceId) + "/heartbeat", null);
    }
    public Map<String, Object> serviceDeregister(String service, String instanceId) {
        return request("DELETE", "/v1/services/" + enc(service) + "/instances/" + enc(instanceId), null);
    }
    public Map<String, Object> serviceInstances(String service) { return request("GET", "/v1/services/" + enc(service), null); }
    public Map<String, Object> serviceList() { return request("GET", "/v1/services", null); }

    // --- high-level support types + helpers ----------------------------------

    /** A held lock grant. Call {@link #release()} (alias {@link #unlock()}) when done. */
    public static final class Lock {
        private final Fiducia c;
        public final List<String> keys;
        public final String holder;
        public final long fencingToken;
        public final Long leaseExpiresMs;
        Lock(Fiducia c, List<String> keys, String holder, long fencingToken, Long leaseExpiresMs) {
            this.c = c; this.keys = keys; this.holder = holder;
            this.fencingToken = fencingToken; this.leaseExpiresMs = leaseExpiresMs;
        }
        public Map<String, Object> release() { return c.lockRelease(holder, fencingToken); }
        public Map<String, Object> unlock() { return release(); }
    }

    /** A held semaphore permit. Call {@link #release()} when done. */
    public static final class SemaphoreHandle {
        private final Fiducia c;
        public final String key;
        public final String holder;
        public final long fencingToken;
        public final Long leaseExpiresMs;
        SemaphoreHandle(Fiducia c, String key, String holder, long fencingToken, Long leaseExpiresMs) {
            this.c = c; this.key = key; this.holder = holder;
            this.fencingToken = fencingToken; this.leaseExpiresMs = leaseExpiresMs;
        }
        public Map<String, Object> release() { return c.semaphoreRelease(key, holder, fencingToken); }
        public Map<String, Object> unlock() { return release(); }
    }

    /** Thrown by blocking lock()/acquireSemaphore() when the wait budget elapses. */
    public static final class LockTimeoutException extends RuntimeException {
        public final List<String> keys;
        public final long waitedMs;
        public LockTimeoutException(List<String> keys, long waitedMs) {
            super("fiducia: timed out after " + waitedMs + "ms waiting for " + keys);
            this.keys = keys; this.waitedMs = waitedMs;
        }
    }

    private static String genHolder() { return "fdc-" + UUID.randomUUID().toString().replace("-", ""); }
    private static long nowMs() { return System.nanoTime() / 1_000_000L; }
    private static void sleep(long ms) {
        try { Thread.sleep(ms); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> asMap(Object o) {
        return (o instanceof Map) ? (Map<String, Object>) o : new HashMap<>();
    }
    private static Map<String, Object> output(Map<String, Object> resp) {
        return asMap(asMap(resp.get("result")).get("output"));
    }
    private static boolean asBool(Object o) { return Boolean.TRUE.equals(o); }
    private static String asStr(Object o) { return (o instanceof String) ? (String) o : null; }
    private static long asLong(Object o) { return (o instanceof Number) ? ((Number) o).longValue() : 0L; }
    private static Long asLongOrNull(Object o) { return (o instanceof Number) ? ((Number) o).longValue() : null; }

    /**
     * Minimal, dependency-free JSON parser + serializer.
     *
     * <ul>
     *   <li>{@link #parse(String)} → Map&lt;String,Object&gt; / List&lt;Object&gt; / String / Double / Boolean / null</li>
     *   <li>{@link #stringify(Object)} ← the same value types (Maps and Lists nest)</li>
     * </ul>
     */
    public static final class Json {
        private final String s;
        private int i;
        private Json(String s) { this.s = s; }

        public static Object parse(String s) {
            if (s == null || s.isEmpty()) return null;
            Json j = new Json(s);
            j.ws();
            return j.value();
        }

        public static String stringify(Object v) {
            StringBuilder b = new StringBuilder();
            write(b, v);
            return b.toString();
        }

        private static void write(StringBuilder b, Object v) {
            if (v == null) {
                b.append("null");
            } else if (v instanceof String) {
                writeString(b, (String) v);
            } else if (v instanceof Boolean || v instanceof Number) {
                b.append(v.toString());
            } else if (v instanceof Map) {
                b.append('{');
                boolean first = true;
                for (Map.Entry<?, ?> e : ((Map<?, ?>) v).entrySet()) {
                    if (!first) b.append(',');
                    first = false;
                    writeString(b, String.valueOf(e.getKey()));
                    b.append(':');
                    write(b, e.getValue());
                }
                b.append('}');
            } else if (v instanceof List) {
                b.append('[');
                boolean first = true;
                for (Object o : (List<?>) v) {
                    if (!first) b.append(',');
                    first = false;
                    write(b, o);
                }
                b.append(']');
            } else {
                writeString(b, v.toString());
            }
        }

        private static void writeString(StringBuilder b, String s) {
            b.append('"');
            for (int i = 0; i < s.length(); i++) {
                char c = s.charAt(i);
                switch (c) {
                    case '"': b.append("\\\""); break;
                    case '\\': b.append("\\\\"); break;
                    case '\n': b.append("\\n"); break;
                    case '\r': b.append("\\r"); break;
                    case '\t': b.append("\\t"); break;
                    case '\b': b.append("\\b"); break;
                    case '\f': b.append("\\f"); break;
                    default:
                        if (c < 0x20) b.append(String.format("\\u%04x", (int) c));
                        else b.append(c);
                }
            }
            b.append('"');
        }

        private Object value() {
            ws();
            char c = s.charAt(i);
            switch (c) {
                case '{': return obj();
                case '[': return arr();
                case '"': return str();
                case 't': i += 4; return Boolean.TRUE;
                case 'f': i += 5; return Boolean.FALSE;
                case 'n': i += 4; return null;
                default:  return num();
            }
        }
        private Map<String, Object> obj() {
            Map<String, Object> m = new LinkedHashMap<>();
            i++; ws();
            if (s.charAt(i) == '}') { i++; return m; }
            while (true) {
                ws();
                String k = str();
                ws(); i++; // ':'
                m.put(k, value());
                ws();
                char c = s.charAt(i++);
                if (c == '}') break; // else ','
            }
            return m;
        }
        private List<Object> arr() {
            List<Object> l = new ArrayList<>();
            i++; ws();
            if (s.charAt(i) == ']') { i++; return l; }
            while (true) {
                l.add(value());
                ws();
                char c = s.charAt(i++);
                if (c == ']') break; // else ','
            }
            return l;
        }
        private String str() {
            StringBuilder b = new StringBuilder();
            i++; // opening quote
            while (true) {
                char c = s.charAt(i++);
                if (c == '"') break;
                if (c == '\\') {
                    char e = s.charAt(i++);
                    switch (e) {
                        case '"': b.append('"'); break;
                        case '\\': b.append('\\'); break;
                        case '/': b.append('/'); break;
                        case 'n': b.append('\n'); break;
                        case 't': b.append('\t'); break;
                        case 'r': b.append('\r'); break;
                        case 'b': b.append('\b'); break;
                        case 'f': b.append('\f'); break;
                        case 'u': b.append((char) Integer.parseInt(s.substring(i, i + 4), 16)); i += 4; break;
                        default: b.append(e);
                    }
                } else b.append(c);
            }
            return b.toString();
        }
        private Object num() {
            int start = i;
            while (i < s.length() && "+-0123456789.eE".indexOf(s.charAt(i)) >= 0) i++;
            return Double.parseDouble(s.substring(start, i));
        }
        private void ws() {
            while (i < s.length() && Character.isWhitespace(s.charAt(i))) i++;
        }
    }
}
