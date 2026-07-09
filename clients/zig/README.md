# fiducia (Zig client)

Thin, dependency-free HTTP client for [fiducia.cloud](https://fiducia.cloud).
Implements the shared `PROTOCOL.md` contract using only the Zig standard library
(`std.http.Client` for transport, `std.json` for encoding/decoding).

- **Zig version:** written and verified against **Zig 0.16.0**. The `std.http`
  and `std.Io` APIs change between Zig releases; this client targets the 0.16.x
  line. Older/newer compilers will need adjustments.
- **Dependencies:** none (standard library only).
- **License:** UNLICENSED / proprietary (see `LICENSE.txt`).

## Install

Zig has no central registry — packages are fetched by URL/tag via
`build.zig.zon`. Add this client to your project:

```sh
zig fetch --save "https://github.com/fiducia-cloud/fiducia-clients/releases/download/clients/zig/v0.1.0/fiducia_client-0.1.0.tar.gz"
```

Then wire the module into your `build.zig`:

```zig
const fiducia_dep = b.dependency("fiducia_client", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("fiducia", fiducia_dep.module("fiducia"));
```

## Usage

```zig
const std = @import("std");
const fiducia = @import("fiducia");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try fiducia.Client.init(allocator, "https://api.fiducia.cloud");
    defer client.deinit();

    const resp = try client.lockAcquire("orders/checkout", .{ .ttl_ms = 30000 });
    defer resp.deinit();

    if (!resp.ok()) {
        std.debug.print("fiducia: HTTP {d}\n", .{resp.status});
        return;
    }
    // resp.value() is a std.json.Value you can walk:
    const out = resp.value().object.get("result").?.object.get("output").?.object;
    const token = out.get("fencing_token").?.string;
    const release = try client.lockRelease("orders/checkout", "worker-a", token);
    defer release.deinit();
}
```

### Return values & errors

Every request method returns a `Response` (the caller owns it — call
`resp.deinit()`):

```zig
pub const Response = struct {
    status: u16,                     // HTTP status
    json: std.json.Parsed(std.json.Value),
    pub fn deinit(self: Response) void;
    pub fn value(self: Response) std.json.Value;   // parsed body; `.null` == empty
    pub fn ok(self: Response) bool;                // status < 300
    pub fn check(self: Response) FiduciaError!void; // error.Http when status >= 300
};
```

This client **does not throw on HTTP status >= 300** — Zig error values can't
carry a payload, and the error body is usually the interesting part. Read
`resp.status` (or `resp.ok()`), and inspect `resp.value()` for the body. If you
prefer error-style flow, `try resp.check()` converts status >= 300 into
`error.Http`.

Transport-level failures (DNS, connect, TLS, malformed response) return
`error.Transport`. The full public error set is:

```zig
pub const FiduciaError = error{ Http, Transport };
pub const Error = FiduciaError || std.mem.Allocator.Error || std.Io.Writer.Error;
```

Optional parameters are passed via a per-call options struct; fields left at
their `null` default are **omitted** from the request body (this matters for
compare-and-set semantics). Method names use Zig-idiomatic `camelCase`.

## Method surface

| Group | Methods |
| --- | --- |
| misc | `health`, `status` |
| locks | `lockGet`, `lockAcquire`, `lockAcquireMany`, `tryLock`, `mustLock`, `lock` (alias), `lockRelease` |
| semaphores | `semaphoreGet`, `semaphoreAcquire`, `trySemaphore`, `mustSemaphore`, `semaphore` (alias), `semaphoreRelease` |
| idempotency | `idempotencyGet`, `idempotencyClaim`, `idempotencyComplete` |
| reader-writer locks | `rwAcquireRead`, `rwEndRead`, `rwAcquireWrite`, `rwEndWrite` |
| config KV | `kvGet`, `kvPut`, `kvDelete`, `kvList` |
| rate limiting | `rateLimitGet`, `rateLimitCheck` |
| cron & scheduling | `scheduleGet`, `scheduleUpsert`, `scheduleRecordRun`, `scheduleHistory` |
| leader election | `electionGet`, `electionCampaign`, `electionRenew`, `electionResign` |
| service discovery | `serviceInstances`, `serviceRegister`, `serviceHeartbeat`, `serviceDeregister`, `serviceList` |

The `try*` / `must*` / `lock` / `semaphore` helpers just flip the `wait` flag on
the corresponding `*Acquire` call — there is no client-side polling loop.

## Develop

```sh
zig build           # build the static library
zig build test      # run unit tests
zig ast-check src/fiducia.zig
```
