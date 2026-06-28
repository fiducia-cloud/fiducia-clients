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
        return request("POST", "/v1/locks/" + enc(key) + "/acquire", obj("ttl_ms", ttlMs, "wait", wait, "max", max));
    }
    public String lockRelease(String key, String lockId) {
        return request("POST", "/v1/locks/" + enc(key) + "/release", obj("lock_id", lockId));
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
