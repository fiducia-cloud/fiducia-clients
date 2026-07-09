// Fiducia HTTP client (Scala, JDK 11+). Transport: java.net.http.HttpClient.
// JSON: com.lihaoyi ujson (the only dependency). Implements PROTOCOL.md.
//
//   val c = new cloud.fiducia.FiduciaClient("https://api.fiducia.cloud")
//   val grant = c.lockAcquire("orders/checkout", ttlMs = Some(30000L))
//   val token = grant("result")("output")("fencing_token").num.toLong
//   c.lockRelease("orders/checkout", "worker-a", token)

package cloud.fiducia

import java.net.URI
import java.net.URLEncoder
import java.net.http.{HttpClient, HttpRequest, HttpResponse}
import java.nio.charset.StandardCharsets
import java.time.Duration
import scala.language.implicitConversions
import scala.util.control.NonFatal

/** Raised on any HTTP response with status >= 300. `body` is the parsed JSON
  * response (`ujson.Null` when the response body was empty). */
final case class FiduciaException(status: Int, body: ujson.Value)
    extends RuntimeException(s"fiducia: HTTP $status")

/** A thin, dependency-light HTTP wrapper over the fiducia.cloud contract. Every
  * method returns the parsed JSON response as a [[ujson.Value]] and throws a
  * [[FiduciaException]] on any non-2xx status.
  *
  * Optional arguments are expressed as `Option`s: a field is included in the
  * request body only when the caller passes `Some(..)` (this matters for the
  * compare-and-swap semantics of `prevRevision`, `holder`, etc.). A supplied
  * `Some(0)` — e.g. `prevRevision = Some(0L)`, meaning "must not exist" — is
  * always sent; it is not dropped as a falsy value.
  *
  * '''Numeric precision:''' ujson's `Num` is `Double`-backed, so 64-bit integers
  * (fencing tokens, KV revisions) are exact only up to 2^53. This client returns
  * the parsed response tree untouched — it never narrows a token to a different
  * type — so read such values straight off the tree, e.g.
  * `resp("result")("output")("fencing_token").num.toLong`. On the request side a
  * `Long` is likewise carried through a `Num`; integral values render as plain
  * integers on the wire (no `.0`, no exponent), exactly up to 2^53 and rounded
  * beyond it. Real monotonic counters never approach 2^53; this ceiling is an
  * inherent limit of the ujson AST, not of the wire protocol.
  *
  * @param baseUrl        service base URL; a trailing slash is trimmed
  * @param requestTimeout connect + per-request timeout applied to every call;
  *                       defaults to 30s. Pass `None` to disable it (e.g. for a
  *                       caller that deliberately blocks on a long `wait`).
  */
class FiduciaClient(
    baseUrl: String,
    requestTimeout: Option[Duration] = Some(Duration.ofSeconds(30))
) {

  private val base: String = baseUrl.replaceAll("/+$", "")
  // Redirects are NOT followed. A 3xx on a mutating POST/PUT/DELETE must surface
  // as an error (status >= 300) rather than silently re-submitting the operation
  // to the Location and duplicating a lock grant / FIFO queue slot. NEVER is also
  // the java.net.http default; pinned here so it cannot drift.
  private val http: HttpClient = {
    val b = HttpClient.newBuilder().followRedirects(HttpClient.Redirect.NEVER)
    requestTimeout.foreach(t => b.connectTimeout(t))
    b.build()
  }

  // --- misc ----------------------------------------------------------------
  def health(): ujson.Value = request("GET", "/healthz")
  def status(): ujson.Value = request("GET", "/v1/status")

  // --- locks ---------------------------------------------------------------
  def lockGet(key: String): ujson.Value =
    request("GET", s"/v1/locks?key=${enc(key)}")

  def lockAcquire(
      key: String,
      holder: Option[String] = None,
      ttlMs: Option[Long] = None,
      wait: Boolean = true
  ): ujson.Value = {
    val b = ujson.Obj("key" -> ujson.Str(key), "wait" -> ujson.Bool(wait))
    putOpt(b, "holder", holder.map(h => ujson.Str(h)))
    putOpt(b, "ttl_ms", ttlMs.map(t => ujson.Num(t.toDouble)))
    request("POST", "/v1/locks/acquire", Some(b))
  }

  /** Atomic multi-key UNION lock: all-or-nothing across the whole set. */
  def lockAcquireMany(
      keys: Seq[String],
      holder: Option[String] = None,
      ttlMs: Option[Long] = None,
      wait: Boolean = true
  ): ujson.Value = {
    val b = ujson.Obj(
      "keys" -> ujson.Arr(keys.map(k => ujson.Str(k)): _*),
      "wait" -> ujson.Bool(wait)
    )
    putOpt(b, "holder", holder.map(h => ujson.Str(h)))
    putOpt(b, "ttl_ms", ttlMs.map(t => ujson.Num(t.toDouble)))
    request("POST", "/v1/locks/acquire", Some(b))
  }

  def tryLock(key: String, holder: Option[String] = None, ttlMs: Option[Long] = None): ujson.Value =
    lockAcquire(key, holder, ttlMs, wait = false)

  def mustLock(key: String, holder: Option[String] = None, ttlMs: Option[Long] = None): ujson.Value =
    lockAcquire(key, holder, ttlMs, wait = true)

  /** Alias for [[mustLock]]. */
  def lock(key: String, holder: Option[String] = None, ttlMs: Option[Long] = None): ujson.Value =
    mustLock(key, holder, ttlMs)

  /** `key` is accepted for symmetry but is not sent (release is by token). */
  def lockRelease(key: String, holder: String, fencingToken: Long): ujson.Value =
    request("POST", "/v1/locks/release", Some(ujson.Obj(
      "holder" -> ujson.Str(holder),
      "fencing_token" -> ujson.Num(fencingToken.toDouble)
    )))

  // --- semaphores ----------------------------------------------------------
  def semaphoreGet(key: String): ujson.Value =
    request("GET", s"/v1/semaphores?key=${enc(key)}")

  def semaphoreAcquire(
      key: String,
      limit: Long,
      holder: Option[String] = None,
      ttlMs: Option[Long] = None,
      wait: Boolean = true
  ): ujson.Value = {
    val b = ujson.Obj(
      "key" -> ujson.Str(key),
      "limit" -> ujson.Num(limit.toDouble),
      "wait" -> ujson.Bool(wait)
    )
    putOpt(b, "holder", holder.map(h => ujson.Str(h)))
    putOpt(b, "ttl_ms", ttlMs.map(t => ujson.Num(t.toDouble)))
    request("POST", "/v1/semaphores/acquire", Some(b))
  }

  def trySemaphore(key: String, limit: Long, holder: Option[String] = None, ttlMs: Option[Long] = None): ujson.Value =
    semaphoreAcquire(key, limit, holder, ttlMs, wait = false)

  def mustSemaphore(key: String, limit: Long, holder: Option[String] = None, ttlMs: Option[Long] = None): ujson.Value =
    semaphoreAcquire(key, limit, holder, ttlMs, wait = true)

  /** Alias for [[mustSemaphore]]. */
  def semaphore(key: String, limit: Long, holder: Option[String] = None, ttlMs: Option[Long] = None): ujson.Value =
    mustSemaphore(key, limit, holder, ttlMs)

  def semaphoreRelease(key: String, holder: String, fencingToken: Long): ujson.Value =
    request("POST", "/v1/semaphores/release", Some(ujson.Obj(
      "key" -> ujson.Str(key),
      "holder" -> ujson.Str(holder),
      "fencing_token" -> ujson.Num(fencingToken.toDouble)
    )))

  // --- idempotency ---------------------------------------------------------
  def idempotencyGet(key: String): ujson.Value =
    request("GET", s"/v1/idempotency?key=${enc(key)}")

  def idempotencyClaim(
      key: String,
      owner: Option[String] = None,
      ttlMs: Option[Long] = None,
      ttl: Option[String] = None,
      metadata: Option[ujson.Value] = None
  ): ujson.Value = {
    val b = ujson.Obj("key" -> ujson.Str(key))
    putOpt(b, "owner", owner.map(o => ujson.Str(o)))
    putOpt(b, "ttl_ms", ttlMs.map(t => ujson.Num(t.toDouble)))
    putOpt(b, "ttl", ttl.map(t => ujson.Str(t)))
    putOpt(b, "metadata", metadata)
    request("POST", "/v1/idempotency/claim", Some(b))
  }

  def idempotencyComplete(
      key: String,
      owner: String,
      fencingToken: Long,
      result: Option[ujson.Value] = None
  ): ujson.Value = {
    val b = ujson.Obj(
      "key" -> ujson.Str(key),
      "owner" -> ujson.Str(owner),
      "fencing_token" -> ujson.Num(fencingToken.toDouble)
    )
    putOpt(b, "result", result)
    request("POST", "/v1/idempotency/complete", Some(b))
  }

  // --- reader-writer locks -------------------------------------------------
  def rwAcquireRead(key: String, ttlMs: Option[Long] = None, wait: Boolean = true): ujson.Value = {
    val b = ujson.Obj("wait" -> ujson.Bool(wait))
    putOpt(b, "ttl_ms", ttlMs.map(t => ujson.Num(t.toDouble)))
    request("POST", s"/v1/rw/${enc(key)}/read", Some(b))
  }

  def rwEndRead(key: String, lockId: String): ujson.Value =
    request("POST", s"/v1/rw/${enc(key)}/read/end", Some(ujson.Obj("lock_id" -> ujson.Str(lockId))))

  def rwAcquireWrite(key: String, ttlMs: Option[Long] = None, wait: Boolean = true): ujson.Value = {
    val b = ujson.Obj("wait" -> ujson.Bool(wait))
    putOpt(b, "ttl_ms", ttlMs.map(t => ujson.Num(t.toDouble)))
    request("POST", s"/v1/rw/${enc(key)}/write", Some(b))
  }

  def rwEndWrite(key: String, lockId: String): ujson.Value =
    request("POST", s"/v1/rw/${enc(key)}/write/end", Some(ujson.Obj("lock_id" -> ujson.Str(lockId))))

  // --- config KV -----------------------------------------------------------
  def kvGet(key: String): ujson.Value =
    request("GET", s"/v1/kv?key=${enc(key)}")

  /** `prevRevision` is a compare-and-swap guard (`Some(0)` = must-not-exist). */
  def kvPut(
      key: String,
      value: ujson.Value,
      ttlMs: Option[Long] = None,
      prevRevision: Option[Long] = None
  ): ujson.Value = {
    val b = ujson.Obj("value" -> value)
    putOpt(b, "ttl_ms", ttlMs.map(t => ujson.Num(t.toDouble)))
    putOpt(b, "prev_revision", prevRevision.map(r => ujson.Num(r.toDouble)))
    request("PUT", s"/v1/kv?key=${enc(key)}", Some(b))
  }

  def kvDelete(key: String): ujson.Value =
    request("DELETE", s"/v1/kv?key=${enc(key)}")

  def kvList(prefix: String): ujson.Value =
    request("GET", s"/v1/kv?prefix=${enc(prefix)}")

  // --- rate limiting -------------------------------------------------------
  def rateLimitGet(tenant: String, key: String): ujson.Value =
    request("GET", s"/v1/rate-limit/${enc(tenant)}/${enc(key)}")

  def rateLimitCheck(
      tenant: String,
      key: String,
      algorithm: String,
      limit: Long,
      windowMs: Long,
      refillPerSecond: Option[Double] = None,
      cost: Option[Long] = None
  ): ujson.Value = {
    val b = ujson.Obj(
      "algorithm" -> ujson.Str(algorithm),
      "limit" -> ujson.Num(limit.toDouble),
      "window_ms" -> ujson.Num(windowMs.toDouble)
    )
    putOpt(b, "refill_per_second", refillPerSecond.map(r => ujson.Num(r)))
    putOpt(b, "cost", cost.map(c => ujson.Num(c.toDouble)))
    request("POST", s"/v1/rate-limit/${enc(tenant)}/${enc(key)}/check", Some(b))
  }

  // --- cron & scheduling ---------------------------------------------------
  def scheduleGet(name: String): ujson.Value =
    request("GET", s"/v1/cron/schedules/${enc(name)}")

  /** `target` is an arbitrary JSON object, e.g. `ujson.Obj("kind" -> "webhook", "url" -> "..")`. */
  def scheduleUpsert(
      name: String,
      target: ujson.Value,
      cron: Option[String] = None,
      oneShotAtMs: Option[Long] = None,
      delivery: Option[String] = None,
      maxRetries: Option[Long] = None
  ): ujson.Value = {
    val b = ujson.Obj("target" -> target)
    putOpt(b, "cron", cron.map(c => ujson.Str(c)))
    putOpt(b, "one_shot_at_ms", oneShotAtMs.map(t => ujson.Num(t.toDouble)))
    putOpt(b, "delivery", delivery.map(d => ujson.Str(d)))
    putOpt(b, "max_retries", maxRetries.map(m => ujson.Num(m.toDouble)))
    request("PUT", s"/v1/cron/schedules/${enc(name)}", Some(b))
  }

  def scheduleRecordRun(name: String, fireId: String, firedAtMs: Option[Long] = None): ujson.Value = {
    val b = ujson.Obj("fire_id" -> ujson.Str(fireId))
    putOpt(b, "fired_at_ms", firedAtMs.map(t => ujson.Num(t.toDouble)))
    request("POST", s"/v1/cron/schedules/${enc(name)}/runs", Some(b))
  }

  def scheduleHistory(name: String): ujson.Value =
    request("GET", s"/v1/cron/schedules/${enc(name)}/history")

  // --- leader election -----------------------------------------------------
  def electionGet(name: String): ujson.Value =
    request("GET", s"/v1/elections/${enc(name)}")

  def electionCampaign(
      name: String,
      candidate: String,
      ttlMs: Long,
      metadata: Option[ujson.Value] = None
  ): ujson.Value = {
    val b = ujson.Obj("candidate" -> ujson.Str(candidate), "ttl_ms" -> ujson.Num(ttlMs.toDouble))
    putOpt(b, "metadata", metadata)
    request("POST", s"/v1/elections/${enc(name)}/campaign", Some(b))
  }

  def electionRenew(name: String, candidate: String, fencingToken: Long): ujson.Value =
    request("POST", s"/v1/elections/${enc(name)}/renew", Some(ujson.Obj(
      "candidate" -> ujson.Str(candidate),
      "fencing_token" -> ujson.Num(fencingToken.toDouble)
    )))

  def electionResign(name: String, candidate: String, fencingToken: Long): ujson.Value =
    request("POST", s"/v1/elections/${enc(name)}/resign", Some(ujson.Obj(
      "candidate" -> ujson.Str(candidate),
      "fencing_token" -> ujson.Num(fencingToken.toDouble)
    )))

  // --- service discovery ---------------------------------------------------
  def serviceInstances(service: String): ujson.Value =
    request("GET", s"/v1/services/${enc(service)}")

  def serviceRegister(
      service: String,
      instanceId: String,
      address: String,
      ttlMs: Long,
      metadata: Option[ujson.Value] = None
  ): ujson.Value = {
    val b = ujson.Obj("address" -> ujson.Str(address), "ttl_ms" -> ujson.Num(ttlMs.toDouble))
    putOpt(b, "metadata", metadata)
    request("PUT", s"/v1/services/${enc(service)}/instances/${enc(instanceId)}", Some(b))
  }

  def serviceHeartbeat(service: String, instanceId: String, ttlMs: Option[Long] = None): ujson.Value = {
    val b = ujson.Obj()
    putOpt(b, "ttl_ms", ttlMs.map(t => ujson.Num(t.toDouble)))
    request("POST", s"/v1/services/${enc(service)}/instances/${enc(instanceId)}/heartbeat", Some(b))
  }

  def serviceDeregister(service: String, instanceId: String): ujson.Value =
    request("DELETE", s"/v1/services/${enc(service)}/instances/${enc(instanceId)}")

  def serviceList(): ujson.Value =
    request("GET", "/v1/services")

  // --- internals -----------------------------------------------------------
  private def putOpt(b: ujson.Obj, key: String, value: Option[ujson.Value]): Unit =
    value.foreach(v => b.obj(key) = v)

  private def enc(s: String): String =
    URLEncoder.encode(s, StandardCharsets.UTF_8).replace("+", "%20")

  private def request(method: String, path: String, body: Option[ujson.Value] = None): ujson.Value = {
    val builder = HttpRequest.newBuilder(URI.create(base + path))
    requestTimeout.foreach(t => builder.timeout(t))
    body match {
      case Some(b) =>
        builder.header("content-type", "application/json")
        builder.method(method, HttpRequest.BodyPublishers.ofString(ujson.write(b)))
      case None =>
        builder.method(method, HttpRequest.BodyPublishers.noBody())
    }
    val response = http.send(builder.build(), HttpResponse.BodyHandlers.ofString())
    val text = response.body()
    // An empty/204 body is null; a non-JSON body (e.g. a proxy's plain-text 502)
    // must not crash the parser and lose the status — fall back to the raw text.
    val data: ujson.Value =
      if (text == null || text.isEmpty) ujson.Null
      else
        try ujson.read(text)
        catch { case NonFatal(_) => ujson.Str(text) }
    if (response.statusCode() >= 300) throw FiduciaException(response.statusCode(), data)
    data
  }
}
