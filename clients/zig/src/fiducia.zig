//! Fiducia HTTP client (Zig, std.http.Client + std.json). Implements PROTOCOL.md.
//! Zero third-party dependencies — Zig standard library only.
//! Written and verified against Zig 0.16.0 (std.http / std.Io are version-sensitive).
//!
//!   const fiducia = @import("fiducia");
//!   var client = try fiducia.Client.init(allocator, "https://api.fiducia.cloud");
//!   defer client.deinit();
//!   const resp = try client.lockAcquire("orders/checkout", .{ .ttl_ms = 30000 });
//!   defer resp.deinit();
//!   // resp.status : u16 (HTTP status; NOT thrown on >= 300 — inspect it / call resp.check())
//!   // resp.value(): std.json.Value (parsed body; a `.null` value means empty body)

const std = @import("std");

const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const Value = std.json.Value;

/// Errors surfaced by the request-issuing methods.
///   * `Transport` — the request could not be completed (DNS, connect, TLS, or a
///     malformed/undecodable response). A non-2xx *remote* status is NOT reported
///     this way; it is surfaced on `Response.status`.
///   * `Http`      — returned only by `Response.check`, when status >= 300.
pub const FiduciaError = error{ Http, Transport };

/// Full error set of the request-issuing methods:
/// `FiduciaError` plus allocation / serialization failures.
pub const Error = FiduciaError || Allocator.Error || std.Io.Writer.Error;

/// The outcome of a single request. The caller owns it and MUST call `deinit`.
///
/// This client does NOT throw on HTTP status >= 300 (Zig error values cannot
/// carry a payload, and the response body is often the interesting part of an
/// error). Instead every completed request yields a `Response`: read `status`,
/// call `ok()`/`check()`, and inspect `value()` for the parsed body.
pub const Response = struct {
    status: u16,
    json: std.json.Parsed(Value),

    pub fn deinit(self: Response) void {
        self.json.deinit();
    }

    /// Parsed JSON body. A `.null` value means the response body was empty.
    pub fn value(self: Response) Value {
        return self.json.value;
    }

    /// True when the HTTP status is < 300.
    pub fn ok(self: Response) bool {
        return self.status < 300;
    }

    /// Returns `error.Http` when the server replied with status >= 300, so
    /// callers who prefer error-style control flow can `try resp.check()`.
    pub fn check(self: Response) FiduciaError!void {
        if (self.status >= 300) return error.Http;
    }
};

// --- option bags (optional fields default to null / their documented default) ---

pub const LockOpts = struct { holder: ?[]const u8 = null, ttl_ms: ?i64 = null, wait: bool = true };
pub const LockWaitOpts = struct { holder: ?[]const u8 = null, ttl_ms: ?i64 = null };
pub const SemaphoreOpts = struct { holder: ?[]const u8 = null, ttl_ms: ?i64 = null, wait: bool = true };
pub const SemaphoreWaitOpts = struct { holder: ?[]const u8 = null, ttl_ms: ?i64 = null };
pub const IdempotencyClaimOpts = struct {
    owner: ?[]const u8 = null,
    ttl_ms: ?i64 = null,
    ttl: ?i64 = null,
    metadata: ?Value = null,
};
pub const IdempotencyCompleteOpts = struct { result: ?Value = null };
pub const RwOpts = struct { ttl_ms: ?i64 = null, wait: bool = true };
pub const KvPutOpts = struct { ttl_ms: ?i64 = null, prev_revision: ?i64 = null };
pub const RateLimitCheckOpts = struct { refill_per_second: ?f64 = null, cost: ?i64 = null };
pub const ScheduleUpsertOpts = struct {
    cron: ?[]const u8 = null,
    one_shot_at_ms: ?i64 = null,
    delivery: ?Value = null,
    max_retries: ?i64 = null,
};
pub const ScheduleRecordRunOpts = struct { fired_at_ms: ?i64 = null };
pub const ElectionCampaignOpts = struct { metadata: ?Value = null };
pub const ServiceRegisterOpts = struct { metadata: ?Value = null };
pub const ServiceHeartbeatOpts = struct { ttl_ms: ?i64 = null };

/// A thin, connection-pooling HTTP wrapper over the Fiducia contract.
///
/// Note: after `init`, do not bit-copy the `Client` value around — pass it by
/// pointer. (The owned I/O backend is heap-pinned, so a stray copy will not
/// dangle, but the connection pool is intended to have a single owner.)
pub const Client = struct {
    allocator: Allocator,
    /// Base URL, trailing slash(es) trimmed. Owned.
    base: []const u8,
    /// Owned, heap-pinned blocking I/O backend for `std.http.Client`.
    io_backend: *std.Io.Threaded,
    http: std.http.Client,

    /// Construct a client for `base_url` (trailing slashes are trimmed).
    pub fn init(allocator: Allocator, base_url: []const u8) Allocator.Error!Client {
        const base = try allocator.dupe(u8, std.mem.trimEnd(u8, base_url, "/"));
        errdefer allocator.free(base);

        const io_backend = try allocator.create(std.Io.Threaded);
        io_backend.* = std.Io.Threaded.init(allocator, .{});

        return .{
            .allocator = allocator,
            .base = base,
            .io_backend = io_backend,
            .http = .{ .allocator = allocator, .io = io_backend.io() },
        };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
        self.io_backend.deinit();
        self.allocator.destroy(self.io_backend);
        self.allocator.free(self.base);
    }

    // ============================ misc ============================

    pub fn health(self: *Client) Error!Response {
        return self.request(.GET, "/healthz", null);
    }

    pub fn status(self: *Client) Error!Response {
        return self.request(.GET, "/v1/status", null);
    }

    // ============================ locks ============================

    pub fn lockGet(self: *Client, key: []const u8) Error!Response {
        const p = try self.path1("/v1/locks?key=", key, "");
        defer self.allocator.free(p);
        return self.request(.GET, p, null);
    }

    pub fn lockAcquire(self: *Client, key: []const u8, opts: LockOpts) Error!Response {
        var sink: std.Io.Writer.Allocating = .init(self.allocator);
        defer sink.deinit();
        var js = Stringify{ .writer = &sink.writer };
        try js.beginObject();
        try fStr(&js, "key", key);
        try fStrOpt(&js, "holder", opts.holder);
        try fIntOpt(&js, "ttl_ms", opts.ttl_ms);
        try fBool(&js, "wait", opts.wait);
        try js.endObject();
        return self.request(.POST, "/v1/locks/acquire", sink.written());
    }

    /// Union lock over several keys (acquired all-or-nothing by the server).
    pub fn lockAcquireMany(self: *Client, keys: []const []const u8, opts: LockOpts) Error!Response {
        var sink: std.Io.Writer.Allocating = .init(self.allocator);
        defer sink.deinit();
        var js = Stringify{ .writer = &sink.writer };
        try js.beginObject();
        try fArr(&js, "keys", keys);
        try fStrOpt(&js, "holder", opts.holder);
        try fIntOpt(&js, "ttl_ms", opts.ttl_ms);
        try fBool(&js, "wait", opts.wait);
        try js.endObject();
        return self.request(.POST, "/v1/locks/acquire", sink.written());
    }

    pub fn tryLock(self: *Client, key: []const u8, opts: LockWaitOpts) Error!Response {
        return self.lockAcquire(key, .{ .holder = opts.holder, .ttl_ms = opts.ttl_ms, .wait = false });
    }

    pub fn mustLock(self: *Client, key: []const u8, opts: LockWaitOpts) Error!Response {
        return self.lockAcquire(key, .{ .holder = opts.holder, .ttl_ms = opts.ttl_ms, .wait = true });
    }

    /// Alias for `mustLock`.
    pub const lock = mustLock;

    /// `key` is accepted for call-site symmetry but is intentionally NOT sent.
    pub fn lockRelease(self: *Client, key: []const u8, holder: []const u8, fencing_token: []const u8) Error!Response {
        _ = key;
        var sink: std.Io.Writer.Allocating = .init(self.allocator);
        defer sink.deinit();
        var js = Stringify{ .writer = &sink.writer };
        try js.beginObject();
        try fStr(&js, "holder", holder);
        try fStr(&js, "fencing_token", fencing_token);
        try js.endObject();
        return self.request(.POST, "/v1/locks/release", sink.written());
    }

    // ========================= semaphores =========================

    pub fn semaphoreGet(self: *Client, key: []const u8) Error!Response {
        const p = try self.path1("/v1/semaphores?key=", key, "");
        defer self.allocator.free(p);
        return self.request(.GET, p, null);
    }

    pub fn semaphoreAcquire(self: *Client, key: []const u8, limit: i64, opts: SemaphoreOpts) Error!Response {
        var sink: std.Io.Writer.Allocating = .init(self.allocator);
        defer sink.deinit();
        var js = Stringify{ .writer = &sink.writer };
        try js.beginObject();
        try fStr(&js, "key", key);
        try fStrOpt(&js, "holder", opts.holder);
        try fIntOpt(&js, "ttl_ms", opts.ttl_ms);
        try fInt(&js, "limit", limit);
        try fBool(&js, "wait", opts.wait);
        try js.endObject();
        return self.request(.POST, "/v1/semaphores/acquire", sink.written());
    }

    pub fn trySemaphore(self: *Client, key: []const u8, limit: i64, opts: SemaphoreWaitOpts) Error!Response {
        return self.semaphoreAcquire(key, limit, .{ .holder = opts.holder, .ttl_ms = opts.ttl_ms, .wait = false });
    }

    pub fn mustSemaphore(self: *Client, key: []const u8, limit: i64, opts: SemaphoreWaitOpts) Error!Response {
        return self.semaphoreAcquire(key, limit, .{ .holder = opts.holder, .ttl_ms = opts.ttl_ms, .wait = true });
    }

    /// Alias for `mustSemaphore`.
    pub const semaphore = mustSemaphore;

    pub fn semaphoreRelease(self: *Client, key: []const u8, holder: []const u8, fencing_token: []const u8) Error!Response {
        var sink: std.Io.Writer.Allocating = .init(self.allocator);
        defer sink.deinit();
        var js = Stringify{ .writer = &sink.writer };
        try js.beginObject();
        try fStr(&js, "key", key);
        try fStr(&js, "holder", holder);
        try fStr(&js, "fencing_token", fencing_token);
        try js.endObject();
        return self.request(.POST, "/v1/semaphores/release", sink.written());
    }

    // ========================= idempotency =========================

    pub fn idempotencyGet(self: *Client, key: []const u8) Error!Response {
        const p = try self.path1("/v1/idempotency?key=", key, "");
        defer self.allocator.free(p);
        return self.request(.GET, p, null);
    }

    pub fn idempotencyClaim(self: *Client, key: []const u8, opts: IdempotencyClaimOpts) Error!Response {
        var sink: std.Io.Writer.Allocating = .init(self.allocator);
        defer sink.deinit();
        var js = Stringify{ .writer = &sink.writer };
        try js.beginObject();
        try fStr(&js, "key", key);
        try fStrOpt(&js, "owner", opts.owner);
        try fIntOpt(&js, "ttl_ms", opts.ttl_ms);
        try fIntOpt(&js, "ttl", opts.ttl);
        try fJsonOpt(&js, "metadata", opts.metadata);
        try js.endObject();
        return self.request(.POST, "/v1/idempotency/claim", sink.written());
    }

    pub fn idempotencyComplete(
        self: *Client,
        key: []const u8,
        owner: []const u8,
        fencing_token: []const u8,
        opts: IdempotencyCompleteOpts,
    ) Error!Response {
        var sink: std.Io.Writer.Allocating = .init(self.allocator);
        defer sink.deinit();
        var js = Stringify{ .writer = &sink.writer };
        try js.beginObject();
        try fStr(&js, "key", key);
        try fStr(&js, "owner", owner);
        try fStr(&js, "fencing_token", fencing_token);
        try fJsonOpt(&js, "result", opts.result);
        try js.endObject();
        return self.request(.POST, "/v1/idempotency/complete", sink.written());
    }

    // ====================== reader-writer locks ======================

    pub fn rwAcquireRead(self: *Client, key: []const u8, opts: RwOpts) Error!Response {
        const p = try self.path1("/v1/rw/", key, "/read");
        defer self.allocator.free(p);
        return self.rwAcquireBody(p, opts);
    }

    pub fn rwEndRead(self: *Client, key: []const u8, lock_id: []const u8) Error!Response {
        const p = try self.path1("/v1/rw/", key, "/read/end");
        defer self.allocator.free(p);
        return self.rwEndBody(p, lock_id);
    }

    pub fn rwAcquireWrite(self: *Client, key: []const u8, opts: RwOpts) Error!Response {
        const p = try self.path1("/v1/rw/", key, "/write");
        defer self.allocator.free(p);
        return self.rwAcquireBody(p, opts);
    }

    pub fn rwEndWrite(self: *Client, key: []const u8, lock_id: []const u8) Error!Response {
        const p = try self.path1("/v1/rw/", key, "/write/end");
        defer self.allocator.free(p);
        return self.rwEndBody(p, lock_id);
    }

    fn rwAcquireBody(self: *Client, path: []const u8, opts: RwOpts) Error!Response {
        var sink: std.Io.Writer.Allocating = .init(self.allocator);
        defer sink.deinit();
        var js = Stringify{ .writer = &sink.writer };
        try js.beginObject();
        try fIntOpt(&js, "ttl_ms", opts.ttl_ms);
        try fBool(&js, "wait", opts.wait);
        try js.endObject();
        return self.request(.POST, path, sink.written());
    }

    fn rwEndBody(self: *Client, path: []const u8, lock_id: []const u8) Error!Response {
        var sink: std.Io.Writer.Allocating = .init(self.allocator);
        defer sink.deinit();
        var js = Stringify{ .writer = &sink.writer };
        try js.beginObject();
        try fStr(&js, "lock_id", lock_id);
        try js.endObject();
        return self.request(.POST, path, sink.written());
    }

    // ============================ config KV ============================

    pub fn kvGet(self: *Client, key: []const u8) Error!Response {
        const p = try self.path1("/v1/kv?key=", key, "");
        defer self.allocator.free(p);
        return self.request(.GET, p, null);
    }

    pub fn kvPut(self: *Client, key: []const u8, val: Value, opts: KvPutOpts) Error!Response {
        const p = try self.path1("/v1/kv?key=", key, "");
        defer self.allocator.free(p);
        var sink: std.Io.Writer.Allocating = .init(self.allocator);
        defer sink.deinit();
        var js = Stringify{ .writer = &sink.writer };
        try js.beginObject();
        try fJson(&js, "value", val);
        try fIntOpt(&js, "ttl_ms", opts.ttl_ms);
        try fIntOpt(&js, "prev_revision", opts.prev_revision);
        try js.endObject();
        return self.request(.PUT, p, sink.written());
    }

    pub fn kvDelete(self: *Client, key: []const u8) Error!Response {
        const p = try self.path1("/v1/kv?key=", key, "");
        defer self.allocator.free(p);
        return self.request(.DELETE, p, null);
    }

    pub fn kvList(self: *Client, prefix: []const u8) Error!Response {
        const p = try self.path1("/v1/kv?prefix=", prefix, "");
        defer self.allocator.free(p);
        return self.request(.GET, p, null);
    }

    // ========================== rate limiting ==========================

    pub fn rateLimitGet(self: *Client, tenant: []const u8, key: []const u8) Error!Response {
        const p = try self.path2("/v1/rate-limit/", tenant, "/", key, "");
        defer self.allocator.free(p);
        return self.request(.GET, p, null);
    }

    pub fn rateLimitCheck(
        self: *Client,
        tenant: []const u8,
        key: []const u8,
        algorithm: []const u8,
        limit: i64,
        window_ms: i64,
        opts: RateLimitCheckOpts,
    ) Error!Response {
        const p = try self.path2("/v1/rate-limit/", tenant, "/", key, "/check");
        defer self.allocator.free(p);
        var sink: std.Io.Writer.Allocating = .init(self.allocator);
        defer sink.deinit();
        var js = Stringify{ .writer = &sink.writer };
        try js.beginObject();
        try fStr(&js, "algorithm", algorithm);
        try fInt(&js, "limit", limit);
        try fInt(&js, "window_ms", window_ms);
        try fFloatOpt(&js, "refill_per_second", opts.refill_per_second);
        try fIntOpt(&js, "cost", opts.cost);
        try js.endObject();
        return self.request(.POST, p, sink.written());
    }

    // ======================== cron & scheduling ========================

    pub fn scheduleGet(self: *Client, name: []const u8) Error!Response {
        const p = try self.path1("/v1/cron/schedules/", name, "");
        defer self.allocator.free(p);
        return self.request(.GET, p, null);
    }

    pub fn scheduleUpsert(self: *Client, name: []const u8, target: Value, opts: ScheduleUpsertOpts) Error!Response {
        const p = try self.path1("/v1/cron/schedules/", name, "");
        defer self.allocator.free(p);
        var sink: std.Io.Writer.Allocating = .init(self.allocator);
        defer sink.deinit();
        var js = Stringify{ .writer = &sink.writer };
        try js.beginObject();
        try fJson(&js, "target", target);
        try fStrOpt(&js, "cron", opts.cron);
        try fIntOpt(&js, "one_shot_at_ms", opts.one_shot_at_ms);
        try fJsonOpt(&js, "delivery", opts.delivery);
        try fIntOpt(&js, "max_retries", opts.max_retries);
        try js.endObject();
        return self.request(.PUT, p, sink.written());
    }

    pub fn scheduleRecordRun(self: *Client, name: []const u8, fire_id: []const u8, opts: ScheduleRecordRunOpts) Error!Response {
        const p = try self.path1("/v1/cron/schedules/", name, "/runs");
        defer self.allocator.free(p);
        var sink: std.Io.Writer.Allocating = .init(self.allocator);
        defer sink.deinit();
        var js = Stringify{ .writer = &sink.writer };
        try js.beginObject();
        try fStr(&js, "fire_id", fire_id);
        try fIntOpt(&js, "fired_at_ms", opts.fired_at_ms);
        try js.endObject();
        return self.request(.POST, p, sink.written());
    }

    pub fn scheduleHistory(self: *Client, name: []const u8) Error!Response {
        const p = try self.path1("/v1/cron/schedules/", name, "/history");
        defer self.allocator.free(p);
        return self.request(.GET, p, null);
    }

    // ========================= leader election =========================

    pub fn electionGet(self: *Client, name: []const u8) Error!Response {
        const p = try self.path1("/v1/elections/", name, "");
        defer self.allocator.free(p);
        return self.request(.GET, p, null);
    }

    pub fn electionCampaign(self: *Client, name: []const u8, candidate: []const u8, ttl_ms: i64, opts: ElectionCampaignOpts) Error!Response {
        const p = try self.path1("/v1/elections/", name, "/campaign");
        defer self.allocator.free(p);
        var sink: std.Io.Writer.Allocating = .init(self.allocator);
        defer sink.deinit();
        var js = Stringify{ .writer = &sink.writer };
        try js.beginObject();
        try fStr(&js, "candidate", candidate);
        try fInt(&js, "ttl_ms", ttl_ms);
        try fJsonOpt(&js, "metadata", opts.metadata);
        try js.endObject();
        return self.request(.POST, p, sink.written());
    }

    pub fn electionRenew(self: *Client, name: []const u8, candidate: []const u8, fencing_token: []const u8) Error!Response {
        const p = try self.path1("/v1/elections/", name, "/renew");
        defer self.allocator.free(p);
        return self.candidateTokenBody(p, candidate, fencing_token);
    }

    pub fn electionResign(self: *Client, name: []const u8, candidate: []const u8, fencing_token: []const u8) Error!Response {
        const p = try self.path1("/v1/elections/", name, "/resign");
        defer self.allocator.free(p);
        return self.candidateTokenBody(p, candidate, fencing_token);
    }

    fn candidateTokenBody(self: *Client, path: []const u8, candidate: []const u8, fencing_token: []const u8) Error!Response {
        var sink: std.Io.Writer.Allocating = .init(self.allocator);
        defer sink.deinit();
        var js = Stringify{ .writer = &sink.writer };
        try js.beginObject();
        try fStr(&js, "candidate", candidate);
        try fStr(&js, "fencing_token", fencing_token);
        try js.endObject();
        return self.request(.POST, path, sink.written());
    }

    // ======================== service discovery ========================

    pub fn serviceList(self: *Client) Error!Response {
        return self.request(.GET, "/v1/services", null);
    }

    pub fn serviceInstances(self: *Client, service: []const u8) Error!Response {
        const p = try self.path1("/v1/services/", service, "");
        defer self.allocator.free(p);
        return self.request(.GET, p, null);
    }

    pub fn serviceRegister(
        self: *Client,
        service: []const u8,
        instance_id: []const u8,
        address: []const u8,
        ttl_ms: i64,
        opts: ServiceRegisterOpts,
    ) Error!Response {
        const p = try self.path2("/v1/services/", service, "/instances/", instance_id, "");
        defer self.allocator.free(p);
        var sink: std.Io.Writer.Allocating = .init(self.allocator);
        defer sink.deinit();
        var js = Stringify{ .writer = &sink.writer };
        try js.beginObject();
        try fStr(&js, "address", address);
        try fInt(&js, "ttl_ms", ttl_ms);
        try fJsonOpt(&js, "metadata", opts.metadata);
        try js.endObject();
        return self.request(.PUT, p, sink.written());
    }

    pub fn serviceHeartbeat(self: *Client, service: []const u8, instance_id: []const u8, opts: ServiceHeartbeatOpts) Error!Response {
        const p = try self.path2("/v1/services/", service, "/instances/", instance_id, "/heartbeat");
        defer self.allocator.free(p);
        var sink: std.Io.Writer.Allocating = .init(self.allocator);
        defer sink.deinit();
        var js = Stringify{ .writer = &sink.writer };
        try js.beginObject();
        try fIntOpt(&js, "ttl_ms", opts.ttl_ms);
        try js.endObject();
        return self.request(.POST, p, sink.written());
    }

    pub fn serviceDeregister(self: *Client, service: []const u8, instance_id: []const u8) Error!Response {
        const p = try self.path2("/v1/services/", service, "/instances/", instance_id, "");
        defer self.allocator.free(p);
        return self.request(.DELETE, p, null);
    }

    // ============================ internals ============================

    /// Build `<base><path>`, issue the request, capture the whole body, and
    /// parse it as JSON (empty body -> a `.null` value). Never throws on a
    /// non-2xx status; that is reported on `Response.status`.
    fn request(self: *Client, method: std.http.Method, path: []const u8, body: ?[]const u8) Error!Response {
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base, path });
        defer self.allocator.free(url);

        var sink: std.Io.Writer.Allocating = .init(self.allocator);
        defer sink.deinit();

        const Headers = std.http.Client.Request.Headers;
        const headers: Headers = if (body != null)
            .{ .content_type = .{ .override = "application/json" } }
        else
            .{};

        const result = self.http.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = body,
            .response_writer = &sink.writer,
            .headers = headers,
        }) catch return error.Transport;

        const bytes = sink.written();
        const parsed = std.json.parseFromSlice(
            Value,
            self.allocator,
            if (bytes.len == 0) "null" else bytes,
            .{},
        ) catch return error.Transport;

        return .{ .status = @intFromEnum(result.status), .json = parsed };
    }

    /// `prefix ++ enc(a) ++ suffix`, owned by the caller.
    fn path1(self: *Client, prefix: []const u8, a: []const u8, suffix: []const u8) Error![]u8 {
        var w: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer w.deinit();
        try w.writer.writeAll(prefix);
        try encodeInto(&w.writer, a);
        try w.writer.writeAll(suffix);
        return w.toOwnedSlice();
    }

    /// `prefix ++ enc(a) ++ mid ++ enc(b) ++ suffix`, owned by the caller.
    fn path2(self: *Client, prefix: []const u8, a: []const u8, mid: []const u8, b: []const u8, suffix: []const u8) Error![]u8 {
        var w: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer w.deinit();
        try w.writer.writeAll(prefix);
        try encodeInto(&w.writer, a);
        try w.writer.writeAll(mid);
        try encodeInto(&w.writer, b);
        try w.writer.writeAll(suffix);
        return w.toOwnedSlice();
    }
};

// --- percent-encoding (RFC 3986 unreserved set kept; everything else %XX) ---

fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => true,
        else => false,
    };
}

fn encodeInto(w: *std.Io.Writer, raw: []const u8) std.Io.Writer.Error!void {
    const hex = "0123456789ABCDEF";
    for (raw) |c| {
        if (isUnreserved(c)) {
            try w.writeByte(c);
        } else {
            try w.writeByte('%');
            try w.writeByte(hex[c >> 4]);
            try w.writeByte(hex[c & 0x0F]);
        }
    }
}

// --- JSON object-field helpers (optional variants omit the key when null) ---

fn fStr(js: *Stringify, name: []const u8, v: []const u8) !void {
    try js.objectField(name);
    try js.write(v);
}
fn fStrOpt(js: *Stringify, name: []const u8, v: ?[]const u8) !void {
    if (v) |x| try fStr(js, name, x);
}
fn fInt(js: *Stringify, name: []const u8, v: i64) !void {
    try js.objectField(name);
    try js.write(v);
}
fn fIntOpt(js: *Stringify, name: []const u8, v: ?i64) !void {
    if (v) |x| try fInt(js, name, x);
}
fn fFloatOpt(js: *Stringify, name: []const u8, v: ?f64) !void {
    if (v) |x| {
        try js.objectField(name);
        try js.write(x);
    }
}
fn fBool(js: *Stringify, name: []const u8, v: bool) !void {
    try js.objectField(name);
    try js.write(v);
}
fn fArr(js: *Stringify, name: []const u8, v: []const []const u8) !void {
    try js.objectField(name);
    try js.write(v);
}
fn fJson(js: *Stringify, name: []const u8, v: Value) !void {
    try js.objectField(name);
    try js.write(v);
}
fn fJsonOpt(js: *Stringify, name: []const u8, v: ?Value) !void {
    if (v) |x| try fJson(js, name, x);
}

// ================================ tests ================================

test "reference all client methods (forces full semantic analysis)" {
    std.testing.refAllDecls(Client);
}

test "base url trims trailing slashes" {
    var c = try Client.init(std.testing.allocator, "https://api.fiducia.cloud///");
    defer c.deinit();
    try std.testing.expectEqualStrings("https://api.fiducia.cloud", c.base);
}

test "percent-encode path/query components" {
    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();
    try encodeInto(&w.writer, "orders/checkout a?b");
    try std.testing.expectEqualStrings("orders%2Fcheckout%20a%3Fb", w.written());
}

test "acquire body omits null optionals and includes wait" {
    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    var js = Stringify{ .writer = &sink.writer };
    try js.beginObject();
    try fStr(&js, "key", "k");
    try fStrOpt(&js, "holder", null);
    try fIntOpt(&js, "ttl_ms", 30000);
    try fBool(&js, "wait", false);
    try js.endObject();
    try std.testing.expectEqualStrings("{\"key\":\"k\",\"ttl_ms\":30000,\"wait\":false}", sink.written());
}

test "response check maps >=300 to error.Http" {
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, "null", .{});
    const r: Response = .{ .status = 409, .json = parsed };
    defer r.deinit();
    try std.testing.expect(!r.ok());
    try std.testing.expectError(error.Http, r.check());
}
