# Fiducia (Swift)

Fiducia HTTP client for Swift. Zero-dependency — Foundation's `URLSession` +
`JSONSerialization`. Implements `PROTOCOL.md`.

## Install

Swift Package Manager. No central registry — depend on the git tag directly:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/fiducia-cloud/fiducia-clients.git", from: "0.1.0"),
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "Fiducia", package: "fiducia-clients"),
    ]),
]
```

(Xcode: File ▸ Add Package Dependencies… and paste the repo URL.)

## Usage

Every method is `async` and returns the parsed JSON response as `Any`
(a `[String: Any]`, `[Any]`, `NSNumber`, `String`, or `NSNull`). An empty body
comes back as `NSNull()`. On HTTP status ≥ 300 a `FiduciaError` is thrown.

```swift
import Fiducia

let c = FiduciaClient(baseURL: "https://api.fiducia.cloud")

// Acquire and release a lock.
let grant = try await c.lockAcquire("orders/checkout", holder: "worker-a", ttlMs: 30000)
let out = ((grant as? [String: Any])?["result"] as? [String: Any])?["output"] as? [String: Any]
if let token = out?["fencing_token"] {
    _ = try await c.lockRelease("orders/checkout", holder: "worker-a", fencingToken: token)
}

// Config KV.
_ = try await c.kvPut("features/beta", value: "on", ttlMs: 60000)
let entry = try await c.kvGet("features/beta")

do {
    _ = try await c.status()
} catch let err as FiduciaError {
    print("HTTP \(err.status):", err.body ?? "<empty>")
}
```

### Method surface

`health` · `status` · `lockGet` · `lockAcquire` · `lockAcquireMany` · `tryLock` ·
`mustLock` · `lock` · `lockRelease` · `semaphoreGet` · `semaphoreAcquire` ·
`trySemaphore` · `mustSemaphore` · `semaphore` · `semaphoreRelease` ·
`idempotencyGet` · `idempotencyClaim` · `idempotencyComplete` · `rwAcquireRead` ·
`rwEndRead` · `rwAcquireWrite` · `rwEndWrite` · `kvGet` · `kvPut` · `kvDelete` ·
`kvList` · `rateLimitGet` · `rateLimitCheck` · `scheduleGet` · `scheduleUpsert` ·
`scheduleRecordRun` · `scheduleHistory` · `electionGet` · `electionCampaign` ·
`electionRenew` · `electionResign` · `serviceList` · `serviceInstances` ·
`serviceRegister` · `serviceHeartbeat` · `serviceDeregister`

Optional parameters (`holder`, `ttlMs`, `metadata`, …) are omitted from the
request body when `nil`, which preserves compare-and-set semantics. The
`try*` / `must*` helpers just flip the `wait` flag on the matching acquire call.

Constructor options: `FiduciaClient(baseURL:session:requestTimeout:)` — pass a
custom `URLSession` or a per-request `requestTimeout` (seconds) if you need them.

## Platforms

macOS 12+, iOS 13+. On iOS 13/14 the client falls back to a `dataTask`
continuation; on macOS 12+/iOS 15+ it uses `URLSession.data(for:)` directly.

## License

Proprietary / `UNLICENSED`. No open-source license has been granted for this
package yet. All rights reserved unless fiducia.cloud grants a separate license.
