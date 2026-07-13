// Fiducia HTTP client (TypeScript). Zero *runtime* dependency — uses the global
// `fetch` (Node 18+ or browsers). Implements PROTOCOL.md.
//
//   import { FiduciaClient } from "./fiducia";
//   import type { KvEntry, LockGrant } from "@fiducia/client";
//   const c = new FiduciaClient("https://api.fiducia.cloud");
//   const lock = await c.mustLock("orders/checkout", { holder: "worker-a", ttlMs: 30000 });
//   await c.lockRelease("orders/checkout", { holder: "worker-a", fencingToken: lock.result.output.fencing_token });

// Shared payload/error contract — re-exported from @fiducia/interfaces so callers
// type responses from one source of truth (these are type-only; no runtime cost).
export type {
  IdempotencyRecord,
  KvEntry,
  KvGetResponse,
  LockGrant,
  Leadership,
  ProposeError,
  ProposeOutcome,
  ServiceInstance,
  ServiceListResponse,
} from "@fiducia/interfaces/typescript";

export interface RequestControlOpts {
  timeoutMs?: number;
  requestTimeoutMs?: number;
  lockRequestTimeoutMs?: number;
  maxRetries?: number;
  retryMax?: number;
  retries?: number;
  retryDelayMs?: number;
  signal?: AbortSignal;
  idempotencyKey?: string;
}

export interface FiduciaClientOpts extends RequestControlOpts {
  fetch?: typeof fetch;
}

export interface AcquireOpts extends RequestControlOpts {
  holder?: string;
  ttlMs?: number;
  wait?: boolean;
  max?: number;
}

export interface AcquireManyOpts extends RequestControlOpts {
  keys: string[];
  holder?: string;
  ttlMs?: number;
  wait?: boolean;
}
export interface ReleaseOpts extends RequestControlOpts { holder: string; fencingToken: number; }
export interface RwOpts extends RequestControlOpts { ttlMs?: number; wait?: boolean; }
export interface KvPutOpts extends RequestControlOpts { ttlMs?: number; prevRevision?: number; }
export interface IdempotencyClaimOpts extends RequestControlOpts {
  owner?: string;
  ttlMs?: number;
  ttl?: string;
  metadata?: Record<string, string>;
}
export interface IdempotencyCompleteOpts extends RequestControlOpts {
  owner: string;
  fencingToken: number;
  result?: Record<string, unknown>;
}
export interface RateLimitCheckOpts extends RequestControlOpts {
  algorithm: "token_bucket" | "sliding_window";
  limit: number;
  windowMs: number;
  refillPerSecond?: number;
  cost?: number;
}
export interface ScheduleTarget {
  kind: "webhook" | "queue" | "grpc";
  url?: string;
  name?: string;
  endpoint?: string;
}
export interface ScheduleUpsertOpts extends RequestControlOpts {
  cron?: string;
  oneShotAtMs?: number;
  target: ScheduleTarget;
  delivery?: "at_least_once" | "exactly_once";
  maxRetries?: number;
}
export interface ElectionCampaignOpts extends RequestControlOpts {
  metadata?: Record<string, string>;
}
export type ServiceMetadataFilter = Record<string, string>;
export interface WatchEvent<T = any> {
  event: string;
  data: T;
  id?: string;
}

export class FiduciaError extends Error {
  status: number;
  body: any;
  headers?: Headers;

  constructor(status: number, body: any, headers?: Headers) {
    super(`fiducia: HTTP ${status}`);
    this.status = status;
    this.body = body;
    this.headers = headers;
  }
}

export class FiduciaTimeoutError extends Error {
  timeoutMs: number;
  method: string;
  path: string;
  attempt: number;

  constructor(
    timeoutMs: number,
    method: string,
    path: string,
    attempt: number,
  ) {
    super(`fiducia: ${method} ${path} timed out after ${timeoutMs}ms`);
    this.name = "FiduciaTimeoutError";
    this.timeoutMs = timeoutMs;
    this.method = method;
    this.path = path;
    this.attempt = attempt;
  }
}

const enc = encodeURIComponent;

// Methods safe to retry without an idempotency key. Per RFC 7231 GET/HEAD/OPTIONS
// and the idempotent-by-contract PUT/DELETE converge to the same server state when
// replayed; only POST (lock/semaphore acquire, release) can duplicate on retry.
function isIdempotentMethod(method: string): boolean {
  const m = method.toUpperCase();
  return m === "GET" || m === "HEAD" || m === "OPTIONS" || m === "PUT" || m === "DELETE";
}

// Collision-resistant key that lets the server dedup a retried mutation. Uses
// Web Crypto (Node 18+, browsers, workers); falls back to a non-crypto id only
// if unavailable — still unique enough to pin a single logical request.
function genIdempotencyKey(): string {
  const c: any = (globalThis as any).crypto;
  if (typeof c?.randomUUID === "function") return `cli_${c.randomUUID()}`;
  if (typeof c?.getRandomValues === "function") {
    const b = new Uint8Array(16);
    c.getRandomValues(b);
    return "cli_" + Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
  }
  return `cli_${Date.now().toString(36)}_${Math.random().toString(36).slice(2)}`;
}

// A response is a redirect if it's a 3xx (Node/undici with redirect:"manual") or
// an opaque redirect (browsers/workers with redirect:"manual" yield status 0).
function isRedirect(res: Response): boolean {
  return res.type === "opaqueredirect" || (res.status >= 300 && res.status < 400);
}

function redirectError(res: Response, method: string, path: string): FiduciaError {
  const location = res.headers?.get?.("location") ?? undefined;
  return new FiduciaError(res.status, {
    error: "redirect_not_followed",
    message: `fiducia: refusing to follow redirect (${res.status || "opaque"}) for ${method} ${path}`,
    location,
  }, res.headers);
}

// Metadata is a string->string map on the wire. Reject non-string values loudly
// (matching the wasm client) instead of silently coercing — a nested object or
// number would otherwise stringify to junk on one client but not another.
function validateMetadata(metadata: Record<string, string> | undefined, where: string): void {
  if (metadata === undefined) return;
  for (const [key, value] of Object.entries(metadata)) {
    if (typeof value !== "string") {
      const got = value === null ? "null" : typeof value;
      throw new TypeError(`fiducia: ${where} metadata["${key}"] must be a string, got ${got}`);
    }
  }
}

// A CR or LF in a header value enables header/response splitting. Node/undici and
// browsers reject these too, but with an opaque error — surface a clear one first.
function assertHeaderValueSafe(name: string, value: string): void {
  if (/[\r\n]/.test(value)) {
    throw new TypeError(`fiducia: ${name} header value contains an illegal CR/LF character`);
  }
}

function serviceMetadataQuery(metadata: ServiceMetadataFilter = {}) {
  validateMetadata(metadata, "service filter");
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(metadata)) {
    if (key.trim()) params.set(`metadata.${key}`, value);
  }
  const query = params.toString();
  return query ? `?${query}` : "";
}

export class FiduciaClient {
  private base: string;
  private fetchImpl: typeof fetch;
  private requestTimeoutMs?: number;
  private lockRequestTimeoutMs?: number;
  private retryMax: number;
  private retryDelayMs: number;

  constructor(baseUrl: string, opts: FiduciaClientOpts = {}) {
    this.base = baseUrl.replace(/\/+$/, "");
    this.fetchImpl = opts.fetch ?? fetch;
    this.requestTimeoutMs = this.pickTimeoutMs({
      timeoutMs: opts.timeoutMs,
      requestTimeoutMs: opts.requestTimeoutMs,
    });
    this.lockRequestTimeoutMs = this.pickTimeoutMs({
      timeoutMs: opts.lockRequestTimeoutMs,
    });
    this.retryMax = this.pickRetryMax(opts);
    this.retryDelayMs = this.pickRetryDelayMs(opts);
  }

  private pickTimeoutMs(opts: RequestControlOpts): number | undefined {
    const value = opts.timeoutMs ?? opts.requestTimeoutMs ?? opts.lockRequestTimeoutMs;
    if (value === undefined) return undefined;
    if (!Number.isFinite(value) || value <= 0) throw new Error("fiducia: timeout must be a positive number of milliseconds");
    return value;
  }

  private pickRetryMax(opts: RequestControlOpts): number {
    const value = opts.maxRetries ?? opts.retryMax ?? opts.retries ?? 0;
    if (!Number.isInteger(value) || value < 0) throw new Error("fiducia: retries must be a non-negative integer");
    return value;
  }

  private pickRetryDelayMs(opts: RequestControlOpts): number {
    const value = opts.retryDelayMs ?? 0;
    if (!Number.isFinite(value) || value < 0) throw new Error("fiducia: retryDelayMs must be a non-negative number");
    return value;
  }

  private resolveTimeoutMs(opts: RequestControlOpts, lockAcquire = false): number | undefined {
    const value = opts.timeoutMs
      ?? (lockAcquire ? opts.lockRequestTimeoutMs : undefined)
      ?? opts.requestTimeoutMs
      ?? (lockAcquire ? this.lockRequestTimeoutMs : undefined)
      ?? this.requestTimeoutMs;
    return this.pickTimeoutMs({ timeoutMs: value });
  }

  private resolveRetryMax(opts: RequestControlOpts): number {
    return this.pickRetryMax({
      maxRetries: opts.maxRetries ?? opts.retryMax ?? opts.retries ?? this.retryMax,
    });
  }

  private resolveRetryDelayMs(opts: RequestControlOpts): number {
    return this.pickRetryDelayMs({ retryDelayMs: opts.retryDelayMs ?? this.retryDelayMs });
  }

  private retryable(err: unknown, signal: AbortSignal | undefined, method: string, idempotencyKey?: string): boolean {
    if (signal?.aborted) return false;
    // Belt-and-suspenders: never retry a non-idempotent mutation that carries no
    // idempotency key — replaying it could duplicate a committed-but-unacked effect.
    // request() attaches a stable key to retry-enabled POSTs, so in practice a key is
    // always present here; this guard keeps the safety even if that ever changes.
    if (!isIdempotentMethod(method) && !idempotencyKey) return false;
    if (err instanceof FiduciaTimeoutError) return true;
    if (err instanceof FiduciaError) return [408, 425, 429, 500, 502, 503, 504].includes(err.status);
    return ["AbortError", "TimeoutError", "TypeError"].includes(String((err as any)?.name));
  }

  private sleep(ms: number, signal?: AbortSignal): Promise<void> {
    if (ms <= 0) return Promise.resolve();
    return new Promise((resolve, reject) => {
      if (signal?.aborted) return reject(signal.reason ?? new Error("fiducia: request aborted"));
      let abortHandler: (() => void) | undefined;
      const done = () => {
        if (abortHandler) signal?.removeEventListener("abort", abortHandler);
        resolve();
      };
      const timer = setTimeout(done, ms);
      abortHandler = () => {
        clearTimeout(timer);
        signal?.removeEventListener("abort", abortHandler!);
        reject(signal?.reason ?? new Error("fiducia: request aborted"));
      };
      signal?.addEventListener("abort", abortHandler, { once: true });
    });
  }

  private async request(
    method: string,
    path: string,
    body?: unknown,
    opts: RequestControlOpts = {},
    lockAcquire = false,
  ): Promise<any> {
    const maxRetries = this.resolveRetryMax(opts);
    const retryDelayMs = this.resolveRetryDelayMs(opts);

    // A retried non-idempotent (mutating) request that committed server-side but
    // whose response was lost would otherwise be silently duplicated — e.g. a
    // second lock/semaphore acquire, a double FIFO slot. When retries are enabled,
    // pin one stable Idempotency-Key across every attempt so the server can dedup.
    // A caller-supplied key wins; GET/HEAD and single-shot (maxRetries=0) calls are
    // left untouched, so this never changes non-retrying behavior.
    let effectiveOpts = opts;
    if (maxRetries > 0 && !isIdempotentMethod(method) && !opts.idempotencyKey) {
      effectiveOpts = { ...opts, idempotencyKey: genIdempotencyKey() };
    }

    for (let attempt = 0; ; attempt += 1) {
      try {
        return await this.requestOnce(method, path, body, effectiveOpts, attempt + 1, lockAcquire);
      } catch (err) {
        if (attempt >= maxRetries || !this.retryable(err, opts.signal, method, effectiveOpts.idempotencyKey)) throw err;
        await this.sleep(retryDelayMs, opts.signal);
      }
    }
  }

  private async requestOnce(
    method: string,
    path: string,
    body: unknown,
    opts: RequestControlOpts,
    attempt: number,
    lockAcquire: boolean,
  ): Promise<any> {
    const timeoutMs = this.resolveTimeoutMs(opts, lockAcquire);
    const controller = timeoutMs !== undefined || opts.signal ? new AbortController() : undefined;
    let timedOut = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let abort: (() => void) | undefined;

    if (opts.signal) {
      if (opts.signal.aborted) throw opts.signal.reason ?? new Error("fiducia: request aborted");
      abort = () => controller?.abort(opts.signal?.reason);
      opts.signal.addEventListener("abort", abort, { once: true });
    }

    if (timeoutMs !== undefined) {
      timer = setTimeout(() => {
        timedOut = true;
        controller?.abort();
      }, timeoutMs);
    }

    try {
      const headers: Record<string, string> = {};
      if (body !== undefined) headers["content-type"] = "application/json";
      if (opts.idempotencyKey) {
        assertHeaderValueSafe("idempotency-key", opts.idempotencyKey);
        headers["idempotency-key"] = opts.idempotencyKey;
      }
      const res = await this.fetchImpl(this.base + path, {
        signal: controller?.signal,
        method,
        headers: Object.keys(headers).length ? headers : undefined,
        body: body !== undefined ? JSON.stringify(body) : undefined,
        redirect: "manual",
      });
      // Hard-reject redirects. A coordination API should never 3xx, and following
      // one would replay this (possibly mutating) request — plus its Authorization
      // and Idempotency-Key headers — to an attacker-controlled Location, including
      // an https->http downgrade. With redirect:"manual" Node exposes the 3xx
      // status; browsers yield an opaque redirect (type "opaqueredirect", status 0).
      if (isRedirect(res)) throw redirectError(res, method, path);
      const text = await res.text();
      const data = text ? JSON.parse(text) : null;
      if (!res.ok) throw new FiduciaError(res.status, data, res.headers);
      return data;
    } catch (err) {
      if (timedOut && timeoutMs !== undefined) throw new FiduciaTimeoutError(timeoutMs, method, path, attempt);
      throw err;
    } finally {
      if (timer) clearTimeout(timer);
      if (abort) opts.signal?.removeEventListener("abort", abort);
    }
  }

  private async *watch(path: string, opts: RequestControlOpts = {}): AsyncGenerator<WatchEvent> {
    const timeoutMs = this.resolveTimeoutMs(opts);
    const controller = timeoutMs !== undefined || opts.signal ? new AbortController() : undefined;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let abort: (() => void) | undefined;

    if (opts.signal) {
      if (opts.signal.aborted) throw opts.signal.reason ?? new Error("fiducia: request aborted");
      abort = () => controller?.abort(opts.signal?.reason);
      opts.signal.addEventListener("abort", abort, { once: true });
    }
    if (timeoutMs !== undefined) {
      timer = setTimeout(() => controller?.abort(), timeoutMs);
    }

    try {
      const res = await this.fetchImpl(this.base + path, {
        method: "GET",
        headers: { accept: "text/event-stream" },
        signal: controller?.signal,
        redirect: "manual",
      });
      if (isRedirect(res)) throw redirectError(res, "GET", path);
      if (!res.ok) {
        const text = await res.text();
        const data = text ? JSON.parse(text) : null;
        throw new FiduciaError(res.status, data, res.headers);
      }
      if (!res.body?.getReader) throw new Error("fiducia: response body is not streamable");

      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";
      try {
        for (;;) {
          const { value, done } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });
          let boundary = buffer.indexOf("\n\n");
          while (boundary >= 0) {
            const block = buffer.slice(0, boundary);
            buffer = buffer.slice(boundary + 2);
            const event = parseSseBlock(block);
            if (event) yield event;
            boundary = buffer.indexOf("\n\n");
          }
        }
        buffer += decoder.decode();
        const event = parseSseBlock(buffer);
        if (event) yield event;
      } finally {
        reader.releaseLock();
      }
    } finally {
      if (timer) clearTimeout(timer);
      if (abort) opts.signal?.removeEventListener("abort", abort);
    }
  }

  private lockAcquireWithWait(key: string, opts: AcquireOpts, wait: boolean) {
    return this.request("POST", "/v1/locks/acquire",
      { key, holder: opts.holder, ttl_ms: opts.ttlMs, wait }, opts, true);
  }

  private acquireOptsFromArgs(optsOrTtlMs?: AcquireOpts | number, maxOrOpts?: number | AcquireOpts, maybeOpts: AcquireOpts = {}): AcquireOpts {
    if (typeof optsOrTtlMs === "object" && optsOrTtlMs !== null) return { ...optsOrTtlMs, max: optsOrTtlMs.max ?? 1 };
    const base: AcquireOpts = typeof maxOrOpts === "object" && maxOrOpts !== null ? maxOrOpts : maybeOpts;
    const ttlMs = typeof optsOrTtlMs === "number" ? optsOrTtlMs : base.ttlMs;
    const max = typeof maxOrOpts === "number" ? maxOrOpts : base.max ?? 1;
    return { ...base, ttlMs, max };
  }

  private lockAcquireManyWithWait(opts: AcquireManyOpts, wait: boolean) {
    return this.request("POST", "/v1/locks/acquire",
      { keys: opts.keys, holder: opts.holder, ttl_ms: opts.ttlMs, wait }, opts, true);
  }

  private semaphoreAcquireWithWait(key: string, opts: AcquireOpts, wait: boolean) {
    return this.request("POST", "/v1/semaphores/acquire",
      { key, holder: opts.holder, ttl_ms: opts.ttlMs, wait, limit: opts.max ?? 2 }, opts, true);
  }

  // --- misc ---
  health() { return this.request("GET", "/healthz"); }
  status() { return this.request("GET", "/v1/status"); }

  // --- locks ---
  lockGet(key: string) {
    return this.request("GET", `/v1/locks?key=${enc(key)}`);
  }
  lockAcquire(key: string, opts: AcquireOpts = {}) {
    return this.lockAcquireWithWait(key, opts, opts.wait ?? false);
  }
  tryLock(key: string, opts?: AcquireOpts): Promise<any>;
  tryLock(key: string, ttlMs: number | undefined): Promise<any>;
  tryLock(key: string, ttlMs: number | undefined, max: number): Promise<any>;
  tryLock(key: string, ttlMs: number | undefined, opts: AcquireOpts): Promise<any>;
  tryLock(key: string, ttlMs: number | undefined, max: number, opts: AcquireOpts): Promise<any>;
  tryLock(key: string, optsOrTtlMs?: AcquireOpts | number, maxOrOpts?: number | AcquireOpts, opts: AcquireOpts = {}) {
    return this.lockAcquireWithWait(key, this.acquireOptsFromArgs(optsOrTtlMs, maxOrOpts, opts), false);
  }
  mustLock(key: string, opts?: AcquireOpts): Promise<any>;
  mustLock(key: string, ttlMs: number | undefined): Promise<any>;
  mustLock(key: string, ttlMs: number | undefined, max: number): Promise<any>;
  mustLock(key: string, ttlMs: number | undefined, opts: AcquireOpts): Promise<any>;
  mustLock(key: string, ttlMs: number | undefined, max: number, opts: AcquireOpts): Promise<any>;
  mustLock(key: string, optsOrTtlMs?: AcquireOpts | number, maxOrOpts?: number | AcquireOpts, opts: AcquireOpts = {}) {
    return this.lockAcquireWithWait(key, this.acquireOptsFromArgs(optsOrTtlMs, maxOrOpts, opts), true);
  }
  lock(key: string, opts?: AcquireOpts): Promise<any>;
  lock(key: string, ttlMs: number | undefined): Promise<any>;
  lock(key: string, ttlMs: number | undefined, max: number): Promise<any>;
  lock(key: string, ttlMs: number | undefined, opts: AcquireOpts): Promise<any>;
  lock(key: string, ttlMs: number | undefined, max: number, opts: AcquireOpts): Promise<any>;
  lock(key: string, optsOrTtlMs?: AcquireOpts | number, maxOrOpts?: number | AcquireOpts, opts: AcquireOpts = {}) {
    return this.mustLock(key, this.acquireOptsFromArgs(optsOrTtlMs, maxOrOpts, opts));
  }
  lockAcquireMany(opts: AcquireManyOpts) {
    return this.lockAcquireManyWithWait(opts, opts.wait ?? false);
  }
  tryLockMany(opts: AcquireManyOpts) {
    return this.lockAcquireManyWithWait(opts, false);
  }
  mustLockMany(opts: AcquireManyOpts) {
    return this.lockAcquireManyWithWait(opts, true);
  }
  lockMany(opts: AcquireManyOpts) {
    return this.mustLockMany(opts);
  }
  lockRelease(key: string, opts: ReleaseOpts) {
    return this.request("POST", "/v1/locks/release",
      { holder: opts.holder, fencing_token: opts.fencingToken }, opts);
  }
  lockReleaseMany(lockId: string) {
    void lockId;
    throw new Error("fiducia: lockReleaseMany(lockId) is legacy; release union locks with lockRelease(key, { holder, fencingToken })");
  }

  // --- semaphores ---
  semaphoreGet(key: string) {
    return this.request("GET", `/v1/semaphores?key=${enc(key)}`);
  }
  semaphoreAcquire(key: string, opts: AcquireOpts = {}) {
    return this.semaphoreAcquireWithWait(key, opts, opts.wait ?? false);
  }
  trySemaphore(key: string, opts: AcquireOpts = {}) {
    return this.semaphoreAcquireWithWait(key, opts, false);
  }
  mustSemaphore(key: string, opts: AcquireOpts = {}) {
    return this.semaphoreAcquireWithWait(key, opts, true);
  }
  semaphore(key: string, opts: AcquireOpts = {}) {
    return this.mustSemaphore(key, opts);
  }
  semaphoreRelease(key: string, opts: ReleaseOpts) {
    return this.request("POST", "/v1/semaphores/release",
      { key, holder: opts.holder, fencing_token: opts.fencingToken }, opts);
  }

  // --- idempotency keys ---
  idempotencyGet(key: string) {
    return this.request("GET", `/v1/idempotency?key=${enc(key)}`);
  }
  idempotencyClaim(key: string, opts: IdempotencyClaimOpts = {}) {
    validateMetadata(opts.metadata, "idempotency claim");
    return this.request("POST", "/v1/idempotency/claim", {
      key,
      owner: opts.owner,
      ttl_ms: opts.ttlMs,
      ttl: opts.ttl,
      metadata: opts.metadata,
    }, opts);
  }
  idempotencyComplete(key: string, opts: IdempotencyCompleteOpts) {
    return this.request("POST", "/v1/idempotency/complete", {
      key,
      owner: opts.owner,
      fencing_token: opts.fencingToken,
      result: opts.result,
    }, opts);
  }

  // --- reader-writer locks ---
  rwAcquireRead(key: string, opts: RwOpts = {}) {
    return this.request("POST", `/v1/rw/${enc(key)}/read`, { ttl_ms: opts.ttlMs, wait: opts.wait ?? true }, opts);
  }
  rwEndRead(key: string, lockId: string, opts: RequestControlOpts = {}) {
    return this.request("POST", `/v1/rw/${enc(key)}/read/end`, { lock_id: lockId }, opts);
  }
  rwAcquireWrite(key: string, opts: RwOpts = {}) {
    return this.request("POST", `/v1/rw/${enc(key)}/write`, { ttl_ms: opts.ttlMs, wait: opts.wait ?? true }, opts);
  }
  rwEndWrite(key: string, lockId: string, opts: RequestControlOpts = {}) {
    return this.request("POST", `/v1/rw/${enc(key)}/write/end`, { lock_id: lockId }, opts);
  }

  // --- config KV ---
  kvGet(key: string) { return this.request("GET", `/v1/kv?key=${enc(key)}`); }
  kvPut(key: string, value: string, opts: KvPutOpts = {}) {
    return this.request("PUT", `/v1/kv?key=${enc(key)}`,
      { value, ttl_ms: opts.ttlMs, prev_revision: opts.prevRevision }, opts);
  }
  kvDelete(key: string, opts: RequestControlOpts = {}) { return this.request("DELETE", `/v1/kv?key=${enc(key)}`, undefined, opts); }
  kvList(prefix: string) { return this.request("GET", `/v1/kv?prefix=${enc(prefix)}`); }
  kvWatch(key: string, opts: RequestControlOpts = {}) {
    return this.watch(`/v1/kv?key=${enc(key)}&watch=true`, opts);
  }
  kvWatchPrefix(prefix: string, opts: RequestControlOpts = {}) {
    return this.watch(`/v1/kv?prefix=${enc(prefix)}&watch=true`, opts);
  }

  // --- rate limiting ---
  rateLimitCheck(tenant: string, key: string, opts: RateLimitCheckOpts) {
    return this.request("POST", `/v1/rate-limit/${enc(tenant)}/${enc(key)}/check`, {
      algorithm: opts.algorithm,
      limit: opts.limit,
      window_ms: opts.windowMs,
      refill_per_second: opts.refillPerSecond,
      cost: opts.cost,
    }, opts);
  }
  rateLimitGet(tenant: string, key: string) {
    return this.request("GET", `/v1/rate-limit/${enc(tenant)}/${enc(key)}`);
  }

  // --- cron / scheduling ---
  scheduleUpsert(name: string, opts: ScheduleUpsertOpts) {
    return this.request("PUT", `/v1/cron/schedules/${enc(name)}`, {
      cron: opts.cron,
      one_shot_at_ms: opts.oneShotAtMs,
      target: opts.target,
      delivery: opts.delivery,
      max_retries: opts.maxRetries,
    }, opts);
  }
  scheduleGet(name: string) {
    return this.request("GET", `/v1/cron/schedules/${enc(name)}`);
  }
  scheduleRecordRun(name: string, fireId: string, firedAtMs?: number) {
    return this.request("POST", `/v1/cron/schedules/${enc(name)}/runs`,
      { fire_id: fireId, fired_at_ms: firedAtMs });
  }
  scheduleHistory(name: string) {
    return this.request("GET", `/v1/cron/schedules/${enc(name)}/history`);
  }

  // --- leader election ---
  electionCampaign(name: string, candidate: string, ttlMs: number, opts: ElectionCampaignOpts = {}) {
    validateMetadata(opts.metadata, "election campaign");
    return this.request("POST", `/v1/elections/${enc(name)}/campaign`, {
      candidate,
      ttl_ms: ttlMs,
      metadata: opts.metadata ?? {},
    }, opts);
  }
  electionRenew(name: string, candidate: string, fencingToken: number) {
    return this.request("POST", `/v1/elections/${enc(name)}/renew`, { candidate, fencing_token: fencingToken });
  }
  electionResign(name: string, candidate: string, fencingToken: number) {
    return this.request("POST", `/v1/elections/${enc(name)}/resign`, { candidate, fencing_token: fencingToken });
  }
  electionGet(name: string) { return this.request("GET", `/v1/elections/${enc(name)}`); }
  electionWatch(name: string, opts: RequestControlOpts = {}) {
    return this.watch(`/v1/elections/${enc(name)}/watch`, opts);
  }

  // --- counters ---
  counterGet(key: string) {
    return this.request("GET", `/v1/counters?key=${enc(key)}`);
  }
  counterAdd(key: string, delta: number, opts: RequestControlOpts & { prevRevision?: number } = {}) {
    return this.request("POST", "/v1/counters/add",
      { key, delta, prev_revision: opts.prevRevision }, opts);
  }
  counterSet(key: string, value: number, opts: RequestControlOpts & { prevRevision?: number } = {}) {
    return this.request("POST", "/v1/counters/set",
      { key, value, prev_revision: opts.prevRevision }, opts);
  }

  // --- barriers ---
  barrierGet(name: string) {
    return this.request("GET", `/v1/barriers?name=${enc(name)}`);
  }
  barrierCreate(
    name: string,
    policy: Record<string, unknown>,
    opts: RequestControlOpts & { expected?: number; deadlineMs?: number } = {},
  ) {
    return this.request("POST", "/v1/barriers/create",
      { name, policy, expected: opts.expected, deadline_ms: opts.deadlineMs }, opts);
  }
  barrierArrive(
    name: string,
    participant: string,
    opts: RequestControlOpts & { weight?: number; veto?: boolean } = {},
  ) {
    return this.request("POST", "/v1/barriers/arrive",
      { name, participant, weight: opts.weight, veto: opts.veto }, opts);
  }

  // --- durable tasks ---
  taskGet(name: string) {
    return this.request("GET", `/v1/tasks?name=${enc(name)}`);
  }
  taskCreate(
    name: string,
    taskType: string,
    opts: RequestControlOpts & { payload?: Record<string, unknown>; deadlineMs?: number } = {},
  ) {
    return this.request("POST", "/v1/tasks/create",
      { name, task_type: taskType, payload: opts.payload, deadline_ms: opts.deadlineMs }, opts);
  }
  taskClaim(name: string, worker: string, opts: RequestControlOpts & { ttlMs?: number } = {}) {
    return this.request("POST", "/v1/tasks/claim",
      { name, worker, ttl_ms: opts.ttlMs }, opts);
  }
  taskProgress(
    name: string,
    worker: string,
    fencingToken: number,
    opts: RequestControlOpts & { percent?: number; checkpoint?: Record<string, unknown> } = {},
  ) {
    return this.request("POST", "/v1/tasks/progress", {
      name,
      worker,
      fencing_token: fencingToken,
      percent: opts.percent,
      checkpoint: opts.checkpoint,
    }, opts);
  }
  taskComplete(
    name: string,
    worker: string,
    fencingToken: number,
    opts: RequestControlOpts & { result?: Record<string, unknown> } = {},
  ) {
    return this.request("POST", "/v1/tasks/complete",
      { name, worker, fencing_token: fencingToken, result: opts.result }, opts);
  }
  taskFail(
    name: string,
    worker: string,
    fencingToken: number,
    opts: RequestControlOpts & { retryable?: boolean } = {},
  ) {
    return this.request("POST", "/v1/tasks/fail",
      { name, worker, fencing_token: fencingToken, retryable: opts.retryable }, opts);
  }
  taskCancel(name: string, opts: RequestControlOpts = {}) {
    return this.request("POST", "/v1/tasks/cancel", { name }, opts);
  }

  // --- approval-escrow effects ---
  effectGet(name: string) {
    return this.request("GET", `/v1/effects?name=${enc(name)}`);
  }
  effectPrepare(
    name: string,
    effectType: string,
    effectIdempotencyKey: string,
    opts: RequestControlOpts & {
      payload?: Record<string, unknown>;
      risk?: string;
      requiredApprovals?: number;
    } = {},
  ) {
    return this.request("POST", "/v1/effects/prepare", {
      name,
      effect_type: effectType,
      payload: opts.payload,
      risk: opts.risk,
      idempotency_key: effectIdempotencyKey,
      required_approvals: opts.requiredApprovals,
    }, opts);
  }
  effectApprove(name: string, principal: string, opts: RequestControlOpts = {}) {
    return this.request("POST", "/v1/effects/approve", { name, principal }, opts);
  }
  effectCommit(
    name: string,
    opts: RequestControlOpts & { result?: Record<string, unknown> } = {},
  ) {
    return this.request("POST", "/v1/effects/commit", { name, result: opts.result }, opts);
  }
  effectAbort(name: string, opts: RequestControlOpts = {}) {
    return this.request("POST", "/v1/effects/abort", { name }, opts);
  }

  // --- ownership handoffs ---
  handoffGet(name: string) {
    return this.request("GET", `/v1/handoffs?name=${enc(name)}`);
  }
  handoffOffer(
    name: string,
    resource: string,
    fromOwner: string,
    toOwner: string,
    fromToken: number,
    opts: RequestControlOpts & { context?: Record<string, unknown>; ttlMs?: number } = {},
  ) {
    return this.request("POST", "/v1/handoffs/offer", {
      name,
      resource,
      from: fromOwner,
      to: toOwner,
      from_token: fromToken,
      context: opts.context,
      ttl_ms: opts.ttlMs,
    }, opts);
  }
  handoffAccept(name: string, toOwner: string, opts: RequestControlOpts = {}) {
    return this.request("POST", "/v1/handoffs/accept", { name, to: toOwner }, opts);
  }
  handoffReject(name: string, toOwner: string, opts: RequestControlOpts = {}) {
    return this.request("POST", "/v1/handoffs/reject", { name, to: toOwner }, opts);
  }

  // --- weighted decisions ---
  decisionGet(name: string) {
    return this.request("GET", `/v1/decisions?name=${enc(name)}`);
  }
  decisionPropose(
    name: string,
    question: string,
    options: Record<string, unknown>,
    policy: Record<string, unknown>,
    opts: RequestControlOpts & { deadlineMs?: number } = {},
  ) {
    return this.request("POST", "/v1/decisions/propose",
      { name, question, options, policy, deadline_ms: opts.deadlineMs }, opts);
  }
  decisionVote(
    name: string,
    voter: string,
    opts: RequestControlOpts & {
      option?: string;
      confidence?: number;
      weight?: number;
      veto?: boolean;
      evidence?: Record<string, unknown>;
    } = {},
  ) {
    return this.request("POST", "/v1/decisions/vote", {
      name,
      voter,
      option: opts.option,
      confidence: opts.confidence,
      weight: opts.weight,
      veto: opts.veto,
      evidence: opts.evidence,
    }, opts);
  }

  // --- hierarchical budgets ---
  budgetGet(name: string) {
    return this.request("GET", `/v1/budgets?name=${enc(name)}`);
  }
  budgetSet(
    name: string,
    limit: Record<string, unknown>,
    opts: RequestControlOpts = {},
  ) {
    return this.request("POST", "/v1/budgets/set", { name, limit }, opts);
  }
  budgetReserve(
    name: string,
    reservationId: string,
    holder: string,
    amount: Record<string, unknown>,
    opts: RequestControlOpts = {},
  ) {
    return this.request("POST", "/v1/budgets/reserve",
      { name, reservation_id: reservationId, holder, amount }, opts);
  }
  budgetCommit(
    name: string,
    reservationId: string,
    actual: Record<string, unknown>,
    opts: RequestControlOpts = {},
  ) {
    return this.request("POST", "/v1/budgets/commit",
      { name, reservation_id: reservationId, actual }, opts);
  }
  budgetRelease(name: string, reservationId: string, opts: RequestControlOpts = {}) {
    return this.request("POST", "/v1/budgets/release",
      { name, reservation_id: reservationId }, opts);
  }

  // --- contestable claims ---
  claimGet(name: string) {
    return this.request("GET", `/v1/claims?name=${enc(name)}`);
  }
  claimAssert(
    name: string,
    subject: string,
    predicate: string,
    author: string,
    opts: RequestControlOpts & {
      value?: Record<string, unknown>;
      confidence?: number;
      evidence?: Record<string, unknown>;
      validUntilMs?: number;
    } = {},
  ) {
    return this.request("POST", "/v1/claims/assert", {
      name,
      subject,
      predicate,
      value: opts.value,
      confidence: opts.confidence,
      author,
      evidence: opts.evidence,
      valid_until_ms: opts.validUntilMs,
    }, opts);
  }
  claimSupport(name: string, agent: string, opts: RequestControlOpts = {}) {
    return this.request("POST", "/v1/claims/support", { name, agent }, opts);
  }
  claimContest(
    name: string,
    agent: string,
    opts: RequestControlOpts & { reason?: string } = {},
  ) {
    return this.request("POST", "/v1/claims/contest",
      { name, agent, reason: opts.reason }, opts);
  }
  claimResolve(name: string, accepted: boolean, opts: RequestControlOpts = {}) {
    return this.request("POST", "/v1/claims/resolve", { name, accepted }, opts);
  }
  claimSupersede(name: string, supersededBy: string, opts: RequestControlOpts = {}) {
    return this.request("POST", "/v1/claims/supersede",
      { name, superseded_by: supersededBy }, opts);
  }

  // --- service discovery ---
  serviceRegister(service: string, instanceId: string, address: string, ttlMs: number, metadata: Record<string, string> = {}) {
    validateMetadata(metadata, "service register");
    return this.request("PUT", `/v1/services/${enc(service)}/instances/${enc(instanceId)}`,
      { address, ttl_ms: ttlMs, metadata });
  }
  serviceHeartbeat(service: string, instanceId: string, ttlMs?: number) {
    return this.request("POST", `/v1/services/${enc(service)}/instances/${enc(instanceId)}/heartbeat`,
      { ttl_ms: ttlMs });
  }
  serviceDeregister(service: string, instanceId: string) {
    return this.request("DELETE", `/v1/services/${enc(service)}/instances/${enc(instanceId)}`);
  }
  serviceInstances(service: string, metadata: ServiceMetadataFilter = {}) {
    return this.request("GET", `/v1/services/${enc(service)}${serviceMetadataQuery(metadata)}`);
  }
  serviceList() { return this.request("GET", "/v1/services"); }
  serviceWatch(service: string, opts: RequestControlOpts = {}) {
    return this.watch(`/v1/services/${enc(service)}/watch`, opts);
  }
}

function parseSseBlock(block: string): WatchEvent | undefined {
  let event = "message";
  let id: string | undefined;
  const data: string[] = [];
  for (const rawLine of block.replace(/\r\n/g, "\n").split("\n")) {
    if (!rawLine || rawLine.startsWith(":")) continue;
    const colon = rawLine.indexOf(":");
    const field = colon >= 0 ? rawLine.slice(0, colon) : rawLine;
    let value = colon >= 0 ? rawLine.slice(colon + 1) : "";
    if (value.startsWith(" ")) value = value.slice(1);
    if (field === "event") event = value;
    if (field === "id") id = value;
    if (field === "data") data.push(value);
  }
  if (!data.length) return undefined;
  const raw = data.join("\n");
  let decoded: any = raw;
  try {
    decoded = JSON.parse(raw);
  } catch {
    decoded = raw;
  }
  return { event, id, data: decoded };
}
