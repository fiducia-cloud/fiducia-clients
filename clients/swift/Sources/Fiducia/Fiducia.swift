// Fiducia HTTP client (Swift). Zero-dependency — Foundation URLSession + JSONSerialization.
// Implements PROTOCOL.md.
//
//   let c = FiduciaClient(baseURL: "https://api.fiducia.cloud")
//   let grant = try await c.lockAcquire("orders/checkout", ttlMs: 30000)
//   let out = ((grant as? [String: Any])?["result"] as? [String: Any])?["output"] as? [String: Any]
//   _ = try await c.lockRelease("orders/checkout", holder: "worker-a", fencingToken: out?["fencing_token"] ?? 0)

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A non-2xx response. Carries the numeric HTTP status and the parsed JSON body
/// (the natural `Any` produced by `JSONSerialization`, or `nil` for an empty body).
public struct FiduciaError: Error, CustomStringConvertible {
    public let status: Int
    public let body: Any?

    public init(status: Int, body: Any?) {
        self.status = status
        self.body = body
    }

    public var description: String { "fiducia: HTTP \(status)" }
}

/// Thin async HTTP wrapper over the fiducia.cloud contract.
///
/// Every method returns the parsed JSON response as `Any` (a `[String: Any]`,
/// `[Any]`, `NSNumber`, `String`, or `NSNull`). An empty response body comes back
/// as `NSNull()`. On HTTP status >= 300 a `FiduciaError` is thrown.
public final class FiduciaClient {
    private let baseURL: String
    private let session: URLSession

    /// Optional per-request timeout (seconds) applied to every request.
    public var requestTimeout: TimeInterval?

    public init(baseURL: String, session: URLSession = .shared, requestTimeout: TimeInterval? = nil) {
        var trimmed = baseURL
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.baseURL = trimmed
        self.session = session
        self.requestTimeout = requestTimeout
    }

    // MARK: - misc

    public func health() async throws -> Any { try await request("GET", "/healthz") }
    public func status() async throws -> Any { try await request("GET", "/v1/status") }

    // MARK: - locks

    public func lockGet(_ key: String) async throws -> Any {
        try await request("GET", "/v1/locks?key=\(Self.enc(key))")
    }

    public func lockAcquire(_ key: String, holder: String? = nil, ttlMs: Int? = nil, wait: Bool = true) async throws -> Any {
        var body: [String: Any] = ["key": key, "wait": wait]
        if let holder = holder { body["holder"] = holder }
        if let ttlMs = ttlMs { body["ttl_ms"] = ttlMs }
        return try await request("POST", "/v1/locks/acquire", body: body)
    }

    /// Atomically acquire a union lock over several keys.
    public func lockAcquireMany(_ keys: [String], holder: String? = nil, ttlMs: Int? = nil, wait: Bool = true) async throws -> Any {
        var body: [String: Any] = ["keys": keys, "wait": wait]
        if let holder = holder { body["holder"] = holder }
        if let ttlMs = ttlMs { body["ttl_ms"] = ttlMs }
        return try await request("POST", "/v1/locks/acquire", body: body)
    }

    public func tryLock(_ key: String, holder: String? = nil, ttlMs: Int? = nil) async throws -> Any {
        try await lockAcquire(key, holder: holder, ttlMs: ttlMs, wait: false)
    }

    public func mustLock(_ key: String, holder: String? = nil, ttlMs: Int? = nil) async throws -> Any {
        try await lockAcquire(key, holder: holder, ttlMs: ttlMs, wait: true)
    }

    /// Alias for `mustLock`.
    public func lock(_ key: String, holder: String? = nil, ttlMs: Int? = nil) async throws -> Any {
        try await mustLock(key, holder: holder, ttlMs: ttlMs)
    }

    /// `key` is accepted for call-site symmetry but is intentionally omitted from the body.
    public func lockRelease(_ key: String, holder: String, fencingToken: Any) async throws -> Any {
        try await request("POST", "/v1/locks/release", body: ["holder": holder, "fencing_token": fencingToken])
    }

    // MARK: - semaphores

    public func semaphoreGet(_ key: String) async throws -> Any {
        try await request("GET", "/v1/semaphores?key=\(Self.enc(key))")
    }

    public func semaphoreAcquire(_ key: String, limit: Int, holder: String? = nil, ttlMs: Int? = nil, wait: Bool = true) async throws -> Any {
        var body: [String: Any] = ["key": key, "limit": limit, "wait": wait]
        if let holder = holder { body["holder"] = holder }
        if let ttlMs = ttlMs { body["ttl_ms"] = ttlMs }
        return try await request("POST", "/v1/semaphores/acquire", body: body)
    }

    public func trySemaphore(_ key: String, limit: Int, holder: String? = nil, ttlMs: Int? = nil) async throws -> Any {
        try await semaphoreAcquire(key, limit: limit, holder: holder, ttlMs: ttlMs, wait: false)
    }

    public func mustSemaphore(_ key: String, limit: Int, holder: String? = nil, ttlMs: Int? = nil) async throws -> Any {
        try await semaphoreAcquire(key, limit: limit, holder: holder, ttlMs: ttlMs, wait: true)
    }

    /// Alias for `mustSemaphore`.
    public func semaphore(_ key: String, limit: Int, holder: String? = nil, ttlMs: Int? = nil) async throws -> Any {
        try await mustSemaphore(key, limit: limit, holder: holder, ttlMs: ttlMs)
    }

    public func semaphoreRelease(_ key: String, holder: String, fencingToken: Any) async throws -> Any {
        try await request("POST", "/v1/semaphores/release", body: ["key": key, "holder": holder, "fencing_token": fencingToken])
    }

    // MARK: - idempotency keys

    public func idempotencyGet(_ key: String) async throws -> Any {
        try await request("GET", "/v1/idempotency?key=\(Self.enc(key))")
    }

    public func idempotencyClaim(_ key: String, owner: String? = nil, ttlMs: Int? = nil, ttl: String? = nil, metadata: [String: Any]? = nil) async throws -> Any {
        var body: [String: Any] = ["key": key]
        if let owner = owner { body["owner"] = owner }
        if let ttlMs = ttlMs { body["ttl_ms"] = ttlMs }
        if let ttl = ttl { body["ttl"] = ttl }
        if let metadata = metadata { body["metadata"] = metadata }
        return try await request("POST", "/v1/idempotency/claim", body: body)
    }

    public func idempotencyComplete(_ key: String, owner: String, fencingToken: Any, result: [String: Any]? = nil) async throws -> Any {
        var body: [String: Any] = ["key": key, "owner": owner, "fencing_token": fencingToken]
        if let result = result { body["result"] = result }
        return try await request("POST", "/v1/idempotency/complete", body: body)
    }

    // MARK: - reader-writer locks

    public func rwAcquireRead(_ key: String, ttlMs: Int? = nil, wait: Bool = true) async throws -> Any {
        var body: [String: Any] = ["wait": wait]
        if let ttlMs = ttlMs { body["ttl_ms"] = ttlMs }
        return try await request("POST", "/v1/rw/\(Self.enc(key))/read", body: body)
    }

    public func rwEndRead(_ key: String, lockId: String) async throws -> Any {
        try await request("POST", "/v1/rw/\(Self.enc(key))/read/end", body: ["lock_id": lockId])
    }

    public func rwAcquireWrite(_ key: String, ttlMs: Int? = nil, wait: Bool = true) async throws -> Any {
        var body: [String: Any] = ["wait": wait]
        if let ttlMs = ttlMs { body["ttl_ms"] = ttlMs }
        return try await request("POST", "/v1/rw/\(Self.enc(key))/write", body: body)
    }

    public func rwEndWrite(_ key: String, lockId: String) async throws -> Any {
        try await request("POST", "/v1/rw/\(Self.enc(key))/write/end", body: ["lock_id": lockId])
    }

    // MARK: - config KV

    public func kvGet(_ key: String) async throws -> Any {
        try await request("GET", "/v1/kv?key=\(Self.enc(key))")
    }

    public func kvPut(_ key: String, value: Any, ttlMs: Int? = nil, prevRevision: Int? = nil) async throws -> Any {
        var body: [String: Any] = ["value": value]
        if let ttlMs = ttlMs { body["ttl_ms"] = ttlMs }
        if let prevRevision = prevRevision { body["prev_revision"] = prevRevision }
        return try await request("PUT", "/v1/kv?key=\(Self.enc(key))", body: body)
    }

    public func kvDelete(_ key: String) async throws -> Any {
        try await request("DELETE", "/v1/kv?key=\(Self.enc(key))")
    }

    public func kvList(prefix: String) async throws -> Any {
        try await request("GET", "/v1/kv?prefix=\(Self.enc(prefix))")
    }

    // MARK: - rate limiting

    public func rateLimitGet(tenant: String, key: String) async throws -> Any {
        try await request("GET", "/v1/rate-limit/\(Self.enc(tenant))/\(Self.enc(key))")
    }

    public func rateLimitCheck(tenant: String, key: String, algorithm: String, limit: Int, windowMs: Int, refillPerSecond: Double? = nil, cost: Int? = nil) async throws -> Any {
        var body: [String: Any] = ["algorithm": algorithm, "limit": limit, "window_ms": windowMs]
        if let refillPerSecond = refillPerSecond { body["refill_per_second"] = refillPerSecond }
        if let cost = cost { body["cost"] = cost }
        return try await request("POST", "/v1/rate-limit/\(Self.enc(tenant))/\(Self.enc(key))/check", body: body)
    }

    // MARK: - cron & scheduling

    public func scheduleGet(_ name: String) async throws -> Any {
        try await request("GET", "/v1/cron/schedules/\(Self.enc(name))")
    }

    public func scheduleUpsert(_ name: String, target: [String: Any], cron: String? = nil, oneShotAtMs: Int? = nil, delivery: String? = nil, maxRetries: Int? = nil) async throws -> Any {
        var body: [String: Any] = ["target": target]
        if let cron = cron { body["cron"] = cron }
        if let oneShotAtMs = oneShotAtMs { body["one_shot_at_ms"] = oneShotAtMs }
        if let delivery = delivery { body["delivery"] = delivery }
        if let maxRetries = maxRetries { body["max_retries"] = maxRetries }
        return try await request("PUT", "/v1/cron/schedules/\(Self.enc(name))", body: body)
    }

    public func scheduleRecordRun(_ name: String, fireId: String, firedAtMs: Int? = nil) async throws -> Any {
        var body: [String: Any] = ["fire_id": fireId]
        if let firedAtMs = firedAtMs { body["fired_at_ms"] = firedAtMs }
        return try await request("POST", "/v1/cron/schedules/\(Self.enc(name))/runs", body: body)
    }

    public func scheduleHistory(_ name: String) async throws -> Any {
        try await request("GET", "/v1/cron/schedules/\(Self.enc(name))/history")
    }

    // MARK: - leader election

    public func electionGet(_ name: String) async throws -> Any {
        try await request("GET", "/v1/elections/\(Self.enc(name))")
    }

    public func electionCampaign(_ name: String, candidate: String, ttlMs: Int, metadata: [String: Any]? = nil) async throws -> Any {
        var body: [String: Any] = ["candidate": candidate, "ttl_ms": ttlMs]
        if let metadata = metadata { body["metadata"] = metadata }
        return try await request("POST", "/v1/elections/\(Self.enc(name))/campaign", body: body)
    }

    public func electionRenew(_ name: String, candidate: String, fencingToken: Any) async throws -> Any {
        try await request("POST", "/v1/elections/\(Self.enc(name))/renew", body: ["candidate": candidate, "fencing_token": fencingToken])
    }

    public func electionResign(_ name: String, candidate: String, fencingToken: Any) async throws -> Any {
        try await request("POST", "/v1/elections/\(Self.enc(name))/resign", body: ["candidate": candidate, "fencing_token": fencingToken])
    }

    // MARK: - service discovery

    public func serviceList() async throws -> Any {
        try await request("GET", "/v1/services")
    }

    public func serviceInstances(_ service: String) async throws -> Any {
        try await request("GET", "/v1/services/\(Self.enc(service))")
    }

    public func serviceRegister(_ service: String, instanceId: String, address: String, ttlMs: Int, metadata: [String: Any]? = nil) async throws -> Any {
        var body: [String: Any] = ["address": address, "ttl_ms": ttlMs]
        if let metadata = metadata { body["metadata"] = metadata }
        return try await request("PUT", "/v1/services/\(Self.enc(service))/instances/\(Self.enc(instanceId))", body: body)
    }

    public func serviceHeartbeat(_ service: String, instanceId: String, ttlMs: Int? = nil) async throws -> Any {
        var body: [String: Any] = [:]
        if let ttlMs = ttlMs { body["ttl_ms"] = ttlMs }
        return try await request("POST", "/v1/services/\(Self.enc(service))/instances/\(Self.enc(instanceId))/heartbeat", body: body)
    }

    public func serviceDeregister(_ service: String, instanceId: String) async throws -> Any {
        try await request("DELETE", "/v1/services/\(Self.enc(service))/instances/\(Self.enc(instanceId))")
    }

    // MARK: - request core

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Any {
        guard let url = URL(string: baseURL + path) else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let timeout = requestTimeout {
            req.timeoutInterval = timeout
        }
        if let body = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }

        let (data, response) = try await perform(req)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        let parsed: Any? = data.isEmpty
            ? nil
            : try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])

        if httpStatus >= 300 {
            throw FiduciaError(status: httpStatus, body: parsed)
        }
        return parsed ?? NSNull()
    }

    /// Uses `URLSession.data(for:)` where available (macOS 12+/iOS 15+) and falls
    /// back to a `dataTask` continuation on older iOS so the async surface still
    /// works down to the package's iOS 13 floor.
    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        if #available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *) {
            return try await session.data(for: request)
        } else {
            return try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let data = data, let response = response {
                        continuation.resume(returning: (data, response))
                    } else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                    }
                }
                task.resume()
            }
        }
    }

    // RFC 3986 unreserved characters — safe in both path segments and query values.
    private static let encAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func enc(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: encAllowed) ?? value
    }
}
