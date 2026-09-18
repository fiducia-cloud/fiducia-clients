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

/// Raised by the blocking acquire helpers (MustLock/Lock/MustSemaphore/Semaphore)
/// when the wait budget elapses before the lock/permit is actually held. Distinct
/// from FiduciaError because a timeout carries no HTTP status or response body.
type LockTimeout(keys: string[], waitedMs: int64) =
    inherit Exception(sprintf "fiducia: timed out after %dms waiting for %s" waitedMs (String.Join(", ", keys)))
    member _.Keys = keys
    member _.WaitedMs = waitedMs

[<AutoOpen>]
module internal Internal =

    // A single, shared HttpClient for the process (mirrors the C# sibling).
    // AllowAutoRedirect is turned OFF: the fixed load balancer routes internally,
    // so a 3xx should never be followed. Following one on a mutating POST/PUT/DELETE
    // could re-submit the operation and duplicate a lock grant / FIFO slot. A 3xx is
    // >= 300, so it surfaces through the normal error path as FiduciaError. (Other
    // handler defaults are left untouched: TLS certificate validation stays ON.)
    let http = new HttpClient(new HttpClientHandler(AllowAutoRedirect = false))

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

    // --- helpers for the blocking (must_*) poll loop ---

    // A stable per-request holder id when the caller did not supply one.
    let genHolder () = "fdc-" + Guid.NewGuid().ToString("N")

    // Null-safe object field access (returns null for a missing key or a non-object).
    let field (n: JsonNode) (k: string) : JsonNode =
        match n with
        | :? JsonObject as o -> (match o.TryGetPropertyValue(k) with | true, v -> v | _ -> null)
        | _ -> null

    // Walk a path of object keys, returning null if any hop is missing.
    let rec dig (n: JsonNode) (path: string list) : JsonNode =
        match path with
        | [] -> n
        | k :: rest -> dig (field n k) rest

    // True only when the node is a JSON boolean true.
    let nodeIsTrue (n: JsonNode) =
        match n with
        | :? JsonValue as v -> (match v.TryGetValue<bool>() with | true, b -> b | _ -> false)
        | _ -> false

    // True only when the node is a JSON string equal to s.
    let nodeEqualsString (n: JsonNode) (s: string) =
        match n with
        | :? JsonValue as v -> (match v.TryGetValue<string>() with | true, x -> x = s | _ -> false)
        | _ -> false

    // Build a normalized held-grant node the caller can release with: our holder
    // plus the proof's fencing_token (+ lease_expires_ms). Nodes are cloned via
    // toNode so they never carry a foreign parent and int64 precision is preserved.
    let heldGrant (holder: string) (fencingToken: JsonNode) (leaseExpiresMs: JsonNode) : JsonNode =
        let g = JsonObject()
        g.["holder"] <- toNode (box holder)
        g.["fencing_token"] <- toNode (box fencingToken)
        if not (isNull leaseExpiresMs) then g.["lease_expires_ms"] <- toNode (box leaseExpiresMs)
        g :> JsonNode

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

    /// Blocking acquire poll loop shared by MustLock/Lock. Sends wait=true; the
    /// server does NOT hold the connection — it returns a queued FIFO ticket
    /// immediately — so if we are not acquired we poll lock_get(key) at a fixed
    /// interval until we hold it (our holder + a fencing_token) or the budget runs
    /// out. Returns a normalized held-grant node {holder, fencing_token,
    /// lease_expires_ms}; raises LockTimeout on deadline / max_retries.
    member private this.AcquireLockBlocking(key: string, holderOpt: string option, ttlMsOpt: int64 option,
                                            maxWaitMs: int64, retryIntervalMs: int64, maxRetriesOpt: int option) : JsonNode =
        let holder = match holderOpt with Some h -> h | None -> genHolder ()
        let ttlMs = defaultArg ttlMsOpt 60000L
        let out = dig (this.LockAcquire(key, holder = holder, ttlMs = ttlMs, wait = true)) [ "result"; "output" ]
        if nodeIsTrue (field out "acquired") then
            heldGrant holder (field out "fencing_token") (field out "lease_expires_ms")
        else
            let deadline = Environment.TickCount64 + maxWaitMs
            let mutable attempt = 0
            let mutable grant : JsonNode = null
            let mutable timedOut = false
            while isNull grant && not timedOut do
                let capped = match maxRetriesOpt with Some m -> attempt >= m | None -> false
                let remaining = deadline - Environment.TickCount64
                if capped || remaining <= 0L then timedOut <- true
                else
                    System.Threading.Thread.Sleep(TimeSpan.FromMilliseconds(float (min retryIntervalMs remaining)))
                    let lk = field (this.LockGet(key)) "lock"
                    if nodeEqualsString (field lk "holder") holder && not (isNull (field lk "fencing_token")) then
                        grant <- heldGrant holder (field lk "fencing_token") (field lk "lease_expires_ms")
                    attempt <- attempt + 1
            if isNull grant then raise (LockTimeout([| key |], maxWaitMs))
            grant

    /// Blocking acquire: blocks until the lock is HELD and returns a grant
    /// {holder, fencing_token, lease_expires_ms} (release via LockRelease), or
    /// raises LockTimeout. Polls lock_get every retryIntervalMs (default 250) until
    /// held or maxWaitMs (default 30000); optional maxRetries caps the poll count.
    member this.MustLock(key: string, ?holder: string, ?ttlMs: int64,
                         ?maxWaitMs: int64, ?retryIntervalMs: int64, ?maxRetries: int) =
        this.AcquireLockBlocking(key, holder, ttlMs, defaultArg maxWaitMs 30000L, defaultArg retryIntervalMs 250L, maxRetries)

    /// Alias for MustLock (blocking acquire).
    member this.Lock(key: string, ?holder: string, ?ttlMs: int64,
                     ?maxWaitMs: int64, ?retryIntervalMs: int64, ?maxRetries: int) =
        this.MustLock(key, ?holder = holder, ?ttlMs = ttlMs, ?maxWaitMs = maxWaitMs,
                      ?retryIntervalMs = retryIntervalMs, ?maxRetries = maxRetries)

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

    /// Blocking acquire poll loop shared by MustSemaphore/Semaphore. Sends wait=true,
    /// and if queued, polls semaphore_get(key).semaphore.holders until our holder
    /// appears with a fencing_token, or the budget runs out. Returns a normalized
    /// held-grant node; raises LockTimeout on deadline / max_retries.
    member private this.AcquireSemaphoreBlocking(key: string, limit: int, holderOpt: string option, ttlMsOpt: int64 option,
                                                 maxWaitMs: int64, retryIntervalMs: int64, maxRetriesOpt: int option) : JsonNode =
        let holder = match holderOpt with Some h -> h | None -> genHolder ()
        let ttlMs = defaultArg ttlMsOpt 60000L
        let out = dig (this.SemaphoreAcquire(key, limit, holder = holder, ttlMs = ttlMs, wait = true)) [ "result"; "output" ]
        if nodeIsTrue (field out "acquired") then
            heldGrant holder (field out "fencing_token") (field out "lease_expires_ms")
        else
            let deadline = Environment.TickCount64 + maxWaitMs
            let mutable attempt = 0
            let mutable grant : JsonNode = null
            let mutable timedOut = false
            while isNull grant && not timedOut do
                let capped = match maxRetriesOpt with Some m -> attempt >= m | None -> false
                let remaining = deadline - Environment.TickCount64
                if capped || remaining <= 0L then timedOut <- true
                else
                    System.Threading.Thread.Sleep(TimeSpan.FromMilliseconds(float (min retryIntervalMs remaining)))
                    match dig (this.SemaphoreGet(key)) [ "semaphore"; "holders" ] with
                    | :? JsonArray as arr ->
                        let slot =
                            arr |> Seq.tryFind (fun h ->
                                nodeEqualsString (field h "holder") holder && not (isNull (field h "fencing_token")))
                        match slot with
                        | Some h -> grant <- heldGrant holder (field h "fencing_token") (field h "lease_expires_ms")
                        | None -> ()
                    | _ -> ()
                    attempt <- attempt + 1
            if isNull grant then raise (LockTimeout([| key |], maxWaitMs))
            grant

    /// Blocking acquire: blocks until a permit is HELD and returns a grant
    /// {holder, fencing_token, lease_expires_ms} (release via SemaphoreRelease), or
    /// raises LockTimeout. Polls semaphore_get every retryIntervalMs (default 250)
    /// until held or maxWaitMs (default 30000); optional maxRetries caps the polls.
    member this.MustSemaphore(key: string, limit: int, ?holder: string, ?ttlMs: int64,
                              ?maxWaitMs: int64, ?retryIntervalMs: int64, ?maxRetries: int) =
        this.AcquireSemaphoreBlocking(key, limit, holder, ttlMs, defaultArg maxWaitMs 30000L, defaultArg retryIntervalMs 250L, maxRetries)

    /// Alias for MustSemaphore (blocking acquire).
    member this.Semaphore(key: string, limit: int, ?holder: string, ?ttlMs: int64,
                          ?maxWaitMs: int64, ?retryIntervalMs: int64, ?maxRetries: int) =
        this.MustSemaphore(key, limit, ?holder = holder, ?ttlMs = ttlMs, ?maxWaitMs = maxWaitMs,
                           ?retryIntervalMs = retryIntervalMs, ?maxRetries = maxRetries)

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
