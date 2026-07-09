// Fiducia HTTP client (Kotlin/JVM, JDK 11+). Transport: java.net.http.HttpClient.
// JSON: kotlinx-serialization-json (returns JsonElement). Implements PROTOCOL.md.
//
//   val c = FiduciaClient("https://api.fiducia.cloud")
//   val lock = c.lockAcquire("orders/checkout", ttlMs = 30000)
//   val token = lock.jsonObject["result"]!!.jsonObject["output"]!!
//       .jsonObject["fencing_token"]!!.jsonPrimitive.long
//   c.lockRelease("orders/checkout", "worker-a", token)

package cloud.fiducia

import java.net.URI
import java.net.URLEncoder
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.nio.charset.StandardCharsets
import java.time.Duration
import java.util.UUID
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** A non-2xx response: carries the numeric HTTP status and the parsed JSON body (or null). */
class FiduciaException(val status: Int, val body: JsonElement?) :
    RuntimeException("fiducia: HTTP $status")

/**
 * Thrown by the blocking [FiduciaClient.mustLock] / [FiduciaClient.mustSemaphore] helpers
 * when the poll budget elapses before this holder is observed holding the grant.
 * Carries the key(s) it was waiting on and the elapsed budget in milliseconds.
 */
class LockTimeoutException(val keys: List<String>, val waitedMs: Long) :
    RuntimeException("fiducia: timed out after ${waitedMs}ms waiting for ${keys.joinToString(", ")}")

/**
 * Thin HTTP wrapper over the fiducia.cloud contract. Every method returns the parsed
 * JSON response as a [JsonElement] (an empty body becomes [JsonNull]) and throws a
 * [FiduciaException] on HTTP status >= 300.
 */
class FiduciaClient(baseUrl: String) {
    private val base: String = baseUrl.trimEnd('/')
    // Do NOT auto-follow redirects: a 3xx on a mutating POST/PUT/DELETE must not be
    // silently re-submitted (it could duplicate a lock grant / queue slot). NEVER is
    // java.net.http's default; pin it explicitly so the safety is not config-dependent.
    private val http: HttpClient = HttpClient.newBuilder()
        .followRedirects(HttpClient.Redirect.NEVER)
        .build()

    /** Per-request timeout (connect + response) applied to every call; set to null to disable. */
    var requestTimeout: Duration? = Duration.ofSeconds(30)

    /** Overrides [requestTimeout] for the blocking acquire calls (locks/semaphores). */
    var lockRequestTimeout: Duration? = null

    /** Number of retries on transient failures (default 0 = no retries). */
    var retryMax: Int = 0

    /** Delay between retries. */
    var retryDelay: Duration = Duration.ZERO

    // --- misc ---
    fun health(): JsonElement = request("GET", "/healthz")
    fun status(): JsonElement = request("GET", "/v1/status")

    // --- locks (single-key + multi-key UNION locks) ---
    fun lockGet(key: String): JsonElement =
        request("GET", "/v1/locks?key=${enc(key)}")

    fun lockAcquire(key: String, holder: String? = null, ttlMs: Long? = null, wait: Boolean = true): JsonElement =
        request("POST", "/v1/locks/acquire", buildJsonObject {
            put("key", key)
            holder?.let { put("holder", it) }
            ttlMs?.let { put("ttl_ms", it) }
            put("wait", wait)
        }, lockAcquire = true)

    fun lockAcquireMany(keys: List<String>, holder: String? = null, ttlMs: Long? = null, wait: Boolean = true): JsonElement =
        request("POST", "/v1/locks/acquire", buildJsonObject {
            put("keys", JsonArray(keys.map { JsonPrimitive(it) }))
            holder?.let { put("holder", it) }
            ttlMs?.let { put("ttl_ms", it) }
            put("wait", wait)
        }, lockAcquire = true)

    fun tryLock(key: String, holder: String? = null, ttlMs: Long? = null): JsonElement =
        lockAcquire(key, holder, ttlMs, wait = false)

    /**
     * Blocks until the lock is held, then returns the held grant; throws [LockTimeoutException]
     * if [maxWaitMs] elapses first. The server does NOT hold the connection on `wait:true` (it
     * reserves a FIFO slot and returns a queued ticket immediately), so this acquires with
     * `wait:true` and then POLLS [lockGet] until this [holder] owns the lock. Returns a JSON
     * object `{acquired:true, holder, key, fencing_token, lease_expires_ms}` — pass `holder` +
     * `fencing_token` to [lockRelease]. [holder] defaults to a generated id; [ttlMs] defaults
     * to 60000; [maxWaitMs] defaults to [lockRequestTimeout] (if set) else 30000.
     */
    fun mustLock(
        key: String,
        holder: String? = null,
        ttlMs: Long? = null,
        maxWaitMs: Long = lockRequestTimeout?.toMillis() ?: DEFAULT_MAX_WAIT_MS,
        retryIntervalMs: Long = DEFAULT_RETRY_INTERVAL_MS,
        maxRetries: Int? = null,
    ): JsonElement {
        val who = holder ?: genHolder()
        val out = field(field(lockAcquire(key, who, ttlMs ?: DEFAULT_TTL_MS, wait = true), "result"), "output")
        if (isTrue(field(out, "acquired"))) {
            return heldGrant(key, who, field(out, "fencing_token"), field(out, "lease_expires_ms"))
        }
        val deadlineNanos = System.nanoTime() + maxWaitMs * NANOS_PER_MS
        var attempts = 0
        while (maxRetries == null || attempts < maxRetries) {
            attempts++
            val remainingMs = (deadlineNanos - System.nanoTime()) / NANOS_PER_MS
            if (remainingMs <= 0) break
            Thread.sleep(minOf(retryIntervalMs, remainingMs))
            val lk = field(lockGet(key), "lock")
            val ft = field(lk, "fencing_token")
            if (holderOf(lk) == who && ft != null && ft !is JsonNull) {
                return heldGrant(key, who, ft, field(lk, "lease_expires_ms"))
            }
        }
        throw LockTimeoutException(listOf(key), maxWaitMs)
    }

    fun lock(
        key: String,
        holder: String? = null,
        ttlMs: Long? = null,
        maxWaitMs: Long = lockRequestTimeout?.toMillis() ?: DEFAULT_MAX_WAIT_MS,
        retryIntervalMs: Long = DEFAULT_RETRY_INTERVAL_MS,
        maxRetries: Int? = null,
    ): JsonElement = mustLock(key, holder, ttlMs, maxWaitMs, retryIntervalMs, maxRetries)

    // `key` is accepted for symmetry with acquire; the release wire body only needs the token.
    fun lockRelease(key: String, holder: String, fencingToken: Long): JsonElement =
        request("POST", "/v1/locks/release", buildJsonObject {
            put("holder", holder)
            put("fencing_token", fencingToken)
        })

    // --- semaphores (counting: up to `limit` concurrent holders) ---
    fun semaphoreGet(key: String): JsonElement =
        request("GET", "/v1/semaphores?key=${enc(key)}")

    fun semaphoreAcquire(key: String, limit: Int, holder: String? = null, ttlMs: Long? = null, wait: Boolean = true): JsonElement =
        request("POST", "/v1/semaphores/acquire", buildJsonObject {
            put("key", key)
            holder?.let { put("holder", it) }
            ttlMs?.let { put("ttl_ms", it) }
            put("limit", limit)
            put("wait", wait)
        }, lockAcquire = true)

    fun trySemaphore(key: String, limit: Int, holder: String? = null, ttlMs: Long? = null): JsonElement =
        semaphoreAcquire(key, limit, holder, ttlMs, wait = false)

    /**
     * Blocks until a semaphore permit is held, then returns the held grant; throws
     * [LockTimeoutException] on timeout. Like [mustLock] but polls [semaphoreGet] and matches
     * this [holder] among `semaphore.holders`. Returns `{acquired:true, holder, key,
     * fencing_token, lease_expires_ms}` — pass `holder` + `fencing_token` to [semaphoreRelease].
     */
    fun mustSemaphore(
        key: String,
        limit: Int,
        holder: String? = null,
        ttlMs: Long? = null,
        maxWaitMs: Long = lockRequestTimeout?.toMillis() ?: DEFAULT_MAX_WAIT_MS,
        retryIntervalMs: Long = DEFAULT_RETRY_INTERVAL_MS,
        maxRetries: Int? = null,
    ): JsonElement {
        val who = holder ?: genHolder()
        val out = field(field(semaphoreAcquire(key, limit, who, ttlMs ?: DEFAULT_TTL_MS, wait = true), "result"), "output")
        if (isTrue(field(out, "acquired"))) {
            return heldGrant(key, who, field(out, "fencing_token"), field(out, "lease_expires_ms"))
        }
        val deadlineNanos = System.nanoTime() + maxWaitMs * NANOS_PER_MS
        var attempts = 0
        while (maxRetries == null || attempts < maxRetries) {
            attempts++
            val remainingMs = (deadlineNanos - System.nanoTime()) / NANOS_PER_MS
            if (remainingMs <= 0) break
            Thread.sleep(minOf(retryIntervalMs, remainingMs))
            val holders = field(field(semaphoreGet(key), "semaphore"), "holders") as? JsonArray
            val slot = holders?.firstOrNull {
                val ft = field(it, "fencing_token")
                holderOf(it) == who && ft != null && ft !is JsonNull
            }
            if (slot != null) {
                return heldGrant(key, who, field(slot, "fencing_token"), field(slot, "lease_expires_ms"))
            }
        }
        throw LockTimeoutException(listOf(key), maxWaitMs)
    }

    fun semaphore(
        key: String,
        limit: Int,
        holder: String? = null,
        ttlMs: Long? = null,
        maxWaitMs: Long = lockRequestTimeout?.toMillis() ?: DEFAULT_MAX_WAIT_MS,
        retryIntervalMs: Long = DEFAULT_RETRY_INTERVAL_MS,
        maxRetries: Int? = null,
    ): JsonElement = mustSemaphore(key, limit, holder, ttlMs, maxWaitMs, retryIntervalMs, maxRetries)

    fun semaphoreRelease(key: String, holder: String, fencingToken: Long): JsonElement =
        request("POST", "/v1/semaphores/release", buildJsonObject {
            put("key", key)
            put("holder", holder)
            put("fencing_token", fencingToken)
        })

    // --- idempotency keys ---
    fun idempotencyGet(key: String): JsonElement =
        request("GET", "/v1/idempotency?key=${enc(key)}")

    fun idempotencyClaim(
        key: String,
        owner: String? = null,
        ttlMs: Long? = null,
        ttl: String? = null,
        metadata: JsonElement? = null,
    ): JsonElement =
        request("POST", "/v1/idempotency/claim", buildJsonObject {
            put("key", key)
            owner?.let { put("owner", it) }
            ttlMs?.let { put("ttl_ms", it) }
            ttl?.let { put("ttl", it) }
            metadata?.let { put("metadata", it) }
        })

    fun idempotencyComplete(key: String, owner: String, fencingToken: Long, result: JsonElement? = null): JsonElement =
        request("POST", "/v1/idempotency/complete", buildJsonObject {
            put("key", key)
            put("owner", owner)
            put("fencing_token", fencingToken)
            result?.let { put("result", it) }
        })

    // --- reader-writer locks ---
    fun rwAcquireRead(key: String, ttlMs: Long? = null, wait: Boolean = true): JsonElement =
        request("POST", "/v1/rw/${enc(key)}/read", buildJsonObject {
            ttlMs?.let { put("ttl_ms", it) }
            put("wait", wait)
        })

    fun rwEndRead(key: String, lockId: String): JsonElement =
        request("POST", "/v1/rw/${enc(key)}/read/end", buildJsonObject { put("lock_id", lockId) })

    fun rwAcquireWrite(key: String, ttlMs: Long? = null, wait: Boolean = true): JsonElement =
        request("POST", "/v1/rw/${enc(key)}/write", buildJsonObject {
            ttlMs?.let { put("ttl_ms", it) }
            put("wait", wait)
        })

    fun rwEndWrite(key: String, lockId: String): JsonElement =
        request("POST", "/v1/rw/${enc(key)}/write/end", buildJsonObject { put("lock_id", lockId) })

    // --- config KV (keys are ?key=, slash-safe) ---
    fun kvGet(key: String): JsonElement =
        request("GET", "/v1/kv?key=${enc(key)}")

    fun kvPut(key: String, value: JsonElement, ttlMs: Long? = null, prevRevision: Long? = null): JsonElement =
        request("PUT", "/v1/kv?key=${enc(key)}", buildJsonObject {
            put("value", value)
            ttlMs?.let { put("ttl_ms", it) }
            prevRevision?.let { put("prev_revision", it) }
        })

    fun kvDelete(key: String): JsonElement =
        request("DELETE", "/v1/kv?key=${enc(key)}")

    fun kvList(prefix: String): JsonElement =
        request("GET", "/v1/kv?prefix=${enc(prefix)}")

    // --- rate limiting ---
    fun rateLimitGet(tenant: String, key: String): JsonElement =
        request("GET", "/v1/rate-limit/${enc(tenant)}/${enc(key)}")

    fun rateLimitCheck(
        tenant: String,
        key: String,
        algorithm: String,
        limit: Int,
        windowMs: Long,
        refillPerSecond: Double? = null,
        cost: Int? = null,
    ): JsonElement =
        request("POST", "/v1/rate-limit/${enc(tenant)}/${enc(key)}/check", buildJsonObject {
            put("algorithm", algorithm)
            put("limit", limit)
            put("window_ms", windowMs)
            refillPerSecond?.let { put("refill_per_second", it) }
            cost?.let { put("cost", it) }
        })

    // --- cron / scheduling ---
    fun scheduleGet(name: String): JsonElement =
        request("GET", "/v1/cron/schedules/${enc(name)}")

    fun scheduleUpsert(
        name: String,
        target: JsonElement,
        cron: String? = null,
        oneShotAtMs: Long? = null,
        delivery: String? = null,
        maxRetries: Int? = null,
    ): JsonElement =
        request("PUT", "/v1/cron/schedules/${enc(name)}", buildJsonObject {
            put("target", target)
            cron?.let { put("cron", it) }
            oneShotAtMs?.let { put("one_shot_at_ms", it) }
            delivery?.let { put("delivery", it) }
            maxRetries?.let { put("max_retries", it) }
        })

    fun scheduleRecordRun(name: String, fireId: String, firedAtMs: Long? = null): JsonElement =
        request("POST", "/v1/cron/schedules/${enc(name)}/runs", buildJsonObject {
            put("fire_id", fireId)
            firedAtMs?.let { put("fired_at_ms", it) }
        })

    fun scheduleHistory(name: String): JsonElement =
        request("GET", "/v1/cron/schedules/${enc(name)}/history")

    // --- leader election ---
    fun electionGet(name: String): JsonElement =
        request("GET", "/v1/elections/${enc(name)}")

    fun electionCampaign(name: String, candidate: String, ttlMs: Long, metadata: JsonElement? = null): JsonElement =
        request("POST", "/v1/elections/${enc(name)}/campaign", buildJsonObject {
            put("candidate", candidate)
            put("ttl_ms", ttlMs)
            metadata?.let { put("metadata", it) }
        })

    fun electionRenew(name: String, candidate: String, fencingToken: Long): JsonElement =
        request("POST", "/v1/elections/${enc(name)}/renew", buildJsonObject {
            put("candidate", candidate)
            put("fencing_token", fencingToken)
        })

    fun electionResign(name: String, candidate: String, fencingToken: Long): JsonElement =
        request("POST", "/v1/elections/${enc(name)}/resign", buildJsonObject {
            put("candidate", candidate)
            put("fencing_token", fencingToken)
        })

    // --- service discovery ---
    fun serviceInstances(service: String): JsonElement =
        request("GET", "/v1/services/${enc(service)}")

    fun serviceRegister(
        service: String,
        instanceId: String,
        address: String,
        ttlMs: Long,
        metadata: JsonElement? = null,
    ): JsonElement =
        request("PUT", "/v1/services/${enc(service)}/instances/${enc(instanceId)}", buildJsonObject {
            put("address", address)
            put("ttl_ms", ttlMs)
            metadata?.let { put("metadata", it) }
        })

    fun serviceHeartbeat(service: String, instanceId: String, ttlMs: Long? = null): JsonElement =
        request("POST", "/v1/services/${enc(service)}/instances/${enc(instanceId)}/heartbeat", buildJsonObject {
            ttlMs?.let { put("ttl_ms", it) }
        })

    fun serviceDeregister(service: String, instanceId: String): JsonElement =
        request("DELETE", "/v1/services/${enc(service)}/instances/${enc(instanceId)}")

    fun serviceList(): JsonElement =
        request("GET", "/v1/services")

    // --- request core ---------------------------------------------------------

    private fun request(method: String, path: String, body: JsonObject? = null, lockAcquire: Boolean = false): JsonElement {
        // One stable Idempotency-Key per logical request, reused on every retry, so a
        // client-side retry of a mutating call cannot duplicate a lock grant / queue slot
        // (the server dedups on the header). Only attached when retries are enabled, so
        // retryMax == 0 sends exactly the bytes it did before.
        val idempotencyKey: String? =
            if (retryMax > 0 && isMutating(method)) UUID.randomUUID().toString() else null
        var attempt = 0
        while (true) {
            try {
                return requestOnce(method, path, body, lockAcquire, idempotencyKey)
            } catch (e: RuntimeException) {
                if (attempt >= retryMax || !retryable(e)) throw e
                attempt++
                if (!retryDelay.isZero && !retryDelay.isNegative) Thread.sleep(retryDelay.toMillis())
            }
        }
    }

    private fun isMutating(method: String): Boolean =
        method == "POST" || method == "PUT" || method == "DELETE"

    private fun requestOnce(method: String, path: String, body: JsonObject?, lockAcquire: Boolean, idempotencyKey: String?): JsonElement {
        val builder = HttpRequest.newBuilder(URI.create(base + path))
        resolveTimeout(lockAcquire)?.let { builder.timeout(it) }
        idempotencyKey?.let { builder.header("Idempotency-Key", it) }
        if (body != null) {
            builder.header("content-type", "application/json")
            builder.method(method, HttpRequest.BodyPublishers.ofString(body.toString()))
        } else {
            builder.method(method, HttpRequest.BodyPublishers.noBody())
        }
        val res: HttpResponse<String> = try {
            http.send(builder.build(), HttpResponse.BodyHandlers.ofString())
        } catch (e: java.io.IOException) {
            throw RuntimeException(e)
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            throw RuntimeException(e)
        }
        val parsed: JsonElement? = parseBody(res.body())
        if (res.statusCode() >= 300) throw FiduciaException(res.statusCode(), parsed)
        return parsed ?: JsonNull
    }

    // Parse the response body as JSON. An empty/absent body (e.g. 204 No Content)
    // is null. A non-JSON body (proxy HTML, a plain-text error, etc.) must NOT crash
    // the client: fall back to the raw text so a FiduciaException can still carry it.
    private fun parseBody(text: String?): JsonElement? {
        if (text.isNullOrEmpty()) return null
        return try {
            Json.parseToJsonElement(text)
        } catch (e: SerializationException) {
            JsonPrimitive(text)
        }
    }

    private fun resolveTimeout(lockAcquire: Boolean): Duration? =
        if (lockAcquire && lockRequestTimeout != null) lockRequestTimeout else requestTimeout

    private fun retryable(e: RuntimeException): Boolean =
        if (e is FiduciaException) e.status in RETRYABLE_STATUS else true

    // Percent-encode for a path segment or query value; URLEncoder emits '+' for
    // spaces, so normalize to %20 which is valid in both positions.
    private fun enc(s: String): String =
        URLEncoder.encode(s, StandardCharsets.UTF_8).replace("+", "%20")

    private companion object {
        private val RETRYABLE_STATUS = setOf(408, 425, 429, 500, 502, 503, 504)
    }
}
