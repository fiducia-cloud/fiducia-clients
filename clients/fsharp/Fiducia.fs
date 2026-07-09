// Fiducia HTTP client (F# / .NET). Uses HttpClient + System.Text.Json (built-in).
// Implements PROTOCOL.md.
//
//   let c = FiduciaClient("https://api.fiducia.cloud")
//   let lck = c.LockAcquire("orders/checkout", ttlMs = 30000L)
//   let token = lck.["result"].["output"].["fencing_token"].GetValue<int64>()
//   c.LockRelease("orders/checkout", "worker-a", token) |> ignore

namespace Fiducia

open System
open System.IO
open System.Net.Http
open System.Text
open System.Text.Json
open System.Text.Json.Nodes

/// Raised on any HTTP status >= 300. Carries the numeric status and the parsed
/// JSON body (may be null when the response body was empty).
type FiduciaError(status: int, body: JsonNode) =
    inherit Exception(sprintf "fiducia: HTTP %d" status)
    member _.Status = status
    member _.Body = body

[<AutoOpen>]
module internal Internal =

    // A single, shared HttpClient for the process (mirrors the C# sibling).
    let http = new HttpClient()

    let enc (s: string) = Uri.EscapeDataString(s)

    // Convert an arbitrary value into a JsonNode. JsonNode values are cloned so
    // they never carry a foreign parent into the request body; everything else
    // is serialized by its runtime type (correct for boxed primitives).
    let toNode (v: obj) : JsonNode =
        match v with
        | null -> null
        | :? JsonNode as n -> JsonNode.Parse(n.ToJsonString())
        | _ -> JsonSerializer.SerializeToNode(v, v.GetType())

    // Always set a field.
    let put (o: JsonObject) (k: string) (v: 'a) = o.[k] <- toNode (box v)

    // Set a field only when the caller supplied it (omit nulls for CAS semantics).
    let putOpt (o: JsonObject) (k: string) (v: 'a option) =
        match v with
        | Some x -> o.[k] <- toNode (box x)
        | None -> ()

    // Parse a response body into a JsonNode. Empty/whitespace -> null. A body that
    // is not valid JSON (e.g. an HTML/plain-text error page) must not crash the
    // parser: fall back to a JSON string node carrying the raw text.
    let parseBody (text: string) : JsonNode =
        if String.IsNullOrWhiteSpace text then null
        else
            try JsonNode.Parse(text)
            with :? JsonException -> JsonValue.Create(text) :> JsonNode

/// Thin HTTP wrapper over the Fiducia contract. Every method issues one request
/// and returns the parsed JSON response as a JsonNode (null for an empty body).
type FiduciaClient(baseUrl: string) =

    let baseUri = baseUrl.TrimEnd('/')

    member private _.Send(method: HttpMethod, path: string, body: JsonNode) : JsonNode =
        use req = new HttpRequestMessage(method, baseUri + path)
        if not (isNull body) then
            req.Content <- new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json")
        use res = http.Send(req)
        use stream = res.Content.ReadAsStream()
        use reader = new StreamReader(stream)
        let text = reader.ReadToEnd()
        let status = int res.StatusCode
        let node = parseBody text
        if status >= 300 then raise (FiduciaError(status, node))
        node

    member private this.Get(path: string) = this.Send(HttpMethod.Get, path, null)
    member private this.Delete(path: string) = this.Send(HttpMethod.Delete, path, null)
    member private this.Post(path: string, body: JsonNode) = this.Send(HttpMethod.Post, path, body)
    member private this.Put(path: string, body: JsonNode) = this.Send(HttpMethod.Put, path, body)

    // --- misc ---
    member this.Health() = this.Get("/healthz")
    member this.Status() = this.Get("/v1/status")

    // --- locks ---
    member this.LockGet(key: string) = this.Get($"/v1/locks?key={enc key}")

    member this.LockAcquire(key: string, ?holder: string, ?ttlMs: int64, ?wait: bool) =
        let o = JsonObject()
        put o "key" key
        putOpt o "holder" holder
        putOpt o "ttl_ms" ttlMs
        put o "wait" (defaultArg wait true)
        this.Post("/v1/locks/acquire", o)

    member this.LockAcquireMany(keys: seq<string>, ?holder: string, ?ttlMs: int64, ?wait: bool) =
        let o = JsonObject()
        put o "keys" (Seq.toArray keys)
        putOpt o "holder" holder
        putOpt o "ttl_ms" ttlMs
        put o "wait" (defaultArg wait true)
        this.Post("/v1/locks/acquire", o)

    member this.TryLock(key: string, ?holder: string, ?ttlMs: int64) =
        this.LockAcquire(key, ?holder = holder, ?ttlMs = ttlMs, wait = false)

    member this.MustLock(key: string, ?holder: string, ?ttlMs: int64) =
        this.LockAcquire(key, ?holder = holder, ?ttlMs = ttlMs, wait = true)

    /// Alias for MustLock (blocking acquire).
    member this.Lock(key: string, ?holder: string, ?ttlMs: int64) =
        this.LockAcquire(key, ?holder = holder, ?ttlMs = ttlMs, wait = true)

    /// `key` is accepted for symmetry but is intentionally not sent in the body.
    member this.LockRelease(key: string, holder: string, fencingToken: int64) =
        let o = JsonObject()
        put o "holder" holder
        put o "fencing_token" fencingToken
        this.Post("/v1/locks/release", o)

    // --- semaphores ---
    member this.SemaphoreGet(key: string) = this.Get($"/v1/semaphores?key={enc key}")

    member this.SemaphoreAcquire(key: string, limit: int, ?holder: string, ?ttlMs: int64, ?wait: bool) =
        let o = JsonObject()
        put o "key" key
        putOpt o "holder" holder
        putOpt o "ttl_ms" ttlMs
        put o "limit" limit
        put o "wait" (defaultArg wait true)
        this.Post("/v1/semaphores/acquire", o)

    member this.TrySemaphore(key: string, limit: int, ?holder: string, ?ttlMs: int64) =
        this.SemaphoreAcquire(key, limit, ?holder = holder, ?ttlMs = ttlMs, wait = false)

    member this.MustSemaphore(key: string, limit: int, ?holder: string, ?ttlMs: int64) =
        this.SemaphoreAcquire(key, limit, ?holder = holder, ?ttlMs = ttlMs, wait = true)

    /// Alias for MustSemaphore (blocking acquire).
    member this.Semaphore(key: string, limit: int, ?holder: string, ?ttlMs: int64) =
        this.SemaphoreAcquire(key, limit, ?holder = holder, ?ttlMs = ttlMs, wait = true)

    member this.SemaphoreRelease(key: string, holder: string, fencingToken: int64) =
        let o = JsonObject()
        put o "key" key
        put o "holder" holder
        put o "fencing_token" fencingToken
        this.Post("/v1/semaphores/release", o)

    // --- idempotency ---
    member this.IdempotencyGet(key: string) = this.Get($"/v1/idempotency?key={enc key}")

    /// `ttl` is arbitrary JSON (e.g. a seconds count or a duration string);
    /// `metadata` is an arbitrary JSON object.
    member this.IdempotencyClaim(key: string, ?owner: string, ?ttlMs: int64, ?ttl: JsonNode, ?metadata: JsonNode) =
        let o = JsonObject()
        put o "key" key
        putOpt o "owner" owner
        putOpt o "ttl_ms" ttlMs
        putOpt o "ttl" ttl
        putOpt o "metadata" metadata
        this.Post("/v1/idempotency/claim", o)

    /// `result` is an arbitrary JSON object.
    member this.IdempotencyComplete(key: string, owner: string, fencingToken: int64, ?result: JsonNode) =
        let o = JsonObject()
        put o "key" key
        put o "owner" owner
        put o "fencing_token" fencingToken
        putOpt o "result" result
        this.Post("/v1/idempotency/complete", o)

    // --- reader-writer locks ---
    member this.RwAcquireRead(key: string, ?ttlMs: int64, ?wait: bool) =
        let o = JsonObject()
        putOpt o "ttl_ms" ttlMs
        put o "wait" (defaultArg wait true)
        this.Post($"/v1/rw/{enc key}/read", o)

    member this.RwEndRead(key: string, lockId: string) =
        let o = JsonObject()
        put o "lock_id" lockId
        this.Post($"/v1/rw/{enc key}/read/end", o)

    member this.RwAcquireWrite(key: string, ?ttlMs: int64, ?wait: bool) =
        let o = JsonObject()
        putOpt o "ttl_ms" ttlMs
        put o "wait" (defaultArg wait true)
        this.Post($"/v1/rw/{enc key}/write", o)

    member this.RwEndWrite(key: string, lockId: string) =
        let o = JsonObject()
        put o "lock_id" lockId
        this.Post($"/v1/rw/{enc key}/write/end", o)

    // --- config KV ---
    member this.KvGet(key: string) = this.Get($"/v1/kv?key={enc key}")

    member this.KvPut(key: string, value: string, ?ttlMs: int64, ?prevRevision: int64) =
        let o = JsonObject()
        put o "value" value
        putOpt o "ttl_ms" ttlMs
        putOpt o "prev_revision" prevRevision
        this.Put($"/v1/kv?key={enc key}", o)

    member this.KvDelete(key: string) = this.Delete($"/v1/kv?key={enc key}")
    member this.KvList(prefix: string) = this.Get($"/v1/kv?prefix={enc prefix}")

    // --- rate limiting ---
    member this.RateLimitGet(tenant: string, key: string) =
        this.Get($"/v1/rate-limit/{enc tenant}/{enc key}")

    member this.RateLimitCheck(tenant: string, key: string, algorithm: string, limit: int64,
                               windowMs: int64, ?refillPerSecond: float, ?cost: int) =
        let o = JsonObject()
        put o "algorithm" algorithm
        put o "limit" limit
        put o "window_ms" windowMs
        putOpt o "refill_per_second" refillPerSecond
        putOpt o "cost" cost
        this.Post($"/v1/rate-limit/{enc tenant}/{enc key}/check", o)

    // --- cron & scheduling ---
    member this.ScheduleGet(name: string) = this.Get($"/v1/cron/schedules/{enc name}")

    /// `target` and `delivery` are arbitrary JSON objects.
    member this.ScheduleUpsert(name: string, target: JsonNode, ?cron: string, ?oneShotAtMs: int64,
                               ?delivery: JsonNode, ?maxRetries: int) =
        let o = JsonObject()
        put o "target" target
        putOpt o "cron" cron
        putOpt o "one_shot_at_ms" oneShotAtMs
        putOpt o "delivery" delivery
        putOpt o "max_retries" maxRetries
        this.Put($"/v1/cron/schedules/{enc name}", o)

    member this.ScheduleRecordRun(name: string, fireId: string, ?firedAtMs: int64) =
        let o = JsonObject()
        put o "fire_id" fireId
        putOpt o "fired_at_ms" firedAtMs
        this.Post($"/v1/cron/schedules/{enc name}/runs", o)

    member this.ScheduleHistory(name: string) = this.Get($"/v1/cron/schedules/{enc name}/history")

    // --- leader election ---
    member this.ElectionGet(name: string) = this.Get($"/v1/elections/{enc name}")

    /// `metadata` is an arbitrary JSON object.
    member this.ElectionCampaign(name: string, candidate: string, ttlMs: int64, ?metadata: JsonNode) =
        let o = JsonObject()
        put o "candidate" candidate
        put o "ttl_ms" ttlMs
        putOpt o "metadata" metadata
        this.Post($"/v1/elections/{enc name}/campaign", o)

    member this.ElectionRenew(name: string, candidate: string, fencingToken: int64) =
        let o = JsonObject()
        put o "candidate" candidate
        put o "fencing_token" fencingToken
        this.Post($"/v1/elections/{enc name}/renew", o)

    member this.ElectionResign(name: string, candidate: string, fencingToken: int64) =
        let o = JsonObject()
        put o "candidate" candidate
        put o "fencing_token" fencingToken
        this.Post($"/v1/elections/{enc name}/resign", o)

    // --- service discovery ---
    member this.ServiceInstances(service: string) = this.Get($"/v1/services/{enc service}")

    /// `metadata` is an arbitrary JSON object.
    member this.ServiceRegister(service: string, instanceId: string, address: string, ttlMs: int64, ?metadata: JsonNode) =
        let o = JsonObject()
        put o "address" address
        put o "ttl_ms" ttlMs
        putOpt o "metadata" metadata
        this.Put($"/v1/services/{enc service}/instances/{enc instanceId}", o)

    member this.ServiceHeartbeat(service: string, instanceId: string, ?ttlMs: int64) =
        let o = JsonObject()
        putOpt o "ttl_ms" ttlMs
        this.Post($"/v1/services/{enc service}/instances/{enc instanceId}/heartbeat", o)

    member this.ServiceDeregister(service: string, instanceId: string) =
        this.Delete($"/v1/services/{enc service}/instances/{enc instanceId}")

    member this.ServiceList() = this.Get("/v1/services")
