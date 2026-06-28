// High-level locking helpers for the Fiducia TypeScript client.
//
// Hand-written (NOT generated): builds the blocking/try/retry ergonomics on top
// of the generated thin `FiduciaClient` in ./fiducia. Mirrors the live-mutex
// client surface so callers get the two shapes they actually want:
//
//   * tryLock(key)   — wait:false. Returns immediately: a Lock if it was free
//                      right now, or null if it's held (no waiting).
//   * lock(key)      — wait:true. Blocks (polling with backoff) until the lock
//   * mustLock(key)    is acquired, the deadline passes (throws LockTimeoutError),
//                      or the server errors. `mustLock` is an alias of `lock`.
//
// Counting semaphores get the same pair: trySemaphore / acquireSemaphore.
//
// The server never holds a request open: `wait:true` reserves a FIFO queue slot
// and returns immediately, so the *client* owns the wait — that's why retry
// cadence (retryInterval), the total budget (maxWaitTime), and the attempt cap
// (maxRetries) all live here, giving the caller full control.

import { FiduciaClient } from "./fiducia";

/** Thrown by `lock`/`acquireSemaphore` when the wait budget elapses unacquired. */
export class LockTimeoutError extends Error {
  constructor(public keys: string[], public waitedMs: number) {
    super(`fiducia: timed out after ${waitedMs}ms waiting for lock on ${keys.join(", ")}`);
    this.name = "LockTimeoutError";
  }
}

/** Thrown when a wait is cancelled via an AbortSignal. */
export class LockAbortedError extends Error {
  constructor(public keys: string[]) {
    super(`fiducia: lock wait aborted for ${keys.join(", ")}`);
    this.name = "LockAbortedError";
  }
}

export interface LockOptions {
  /** Lease TTL in ms — the lock auto-expires if not released (default 60000). */
  ttl?: number;
  /** Caller identity (and the key for release). Defaults to a generated id. */
  holder?: string;
  /** Total time to keep waiting before giving up, for blocking `lock` (default 30000). */
  maxWaitTime?: number;
  /** Max number of poll attempts while waiting (default unlimited). */
  maxRetries?: number;
  /** Delay between polls while waiting, in ms (default 250). */
  retryInterval?: number;
  /** Cancel an in-flight wait. */
  signal?: AbortSignal;
}

export interface Lock {
  /** The member keys held by this grant (a single-key lock has one). */
  keys: string[];
  /** The holder id that owns the grant (needed to release). */
  holder: string;
  /** Monotonic fencing token — pass it to downstream systems to defeat stale holders. */
  fencingToken: number;
  /** When the lease expires (ms since epoch), if the server reported it. */
  leaseExpiresMs?: number;
  /** Release the whole grant. Idempotent-ish; safe to call once. */
  unlock(): Promise<any>;
  /** Alias of `unlock`. */
  release(): Promise<any>;
}

export interface SemaphoreHandle {
  key: string;
  holder: string;
  fencingToken: number;
  leaseExpiresMs?: number;
  unlock(): Promise<any>;
  release(): Promise<any>;
}

const DEFAULT_TTL = 60_000;
const DEFAULT_MAX_WAIT = 30_000;
const DEFAULT_RETRY_INTERVAL = 250;

function genId(): string {
  const g: any = globalThis as any;
  if (g.crypto?.randomUUID) return g.crypto.randomUUID();
  return `fdc-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}

function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    const t = setTimeout(resolve, ms);
    if (signal) {
      const onAbort = () => {
        clearTimeout(t);
        reject(new Error("aborted"));
      };
      if (signal.aborted) onAbort();
      else signal.addEventListener("abort", onAbort, { once: true });
    }
  });
}

/**
 * `FiduciaClient` plus high-level lock/semaphore acquisition. Use this in place
 * of `FiduciaClient` when you want `lock`/`tryLock` rather than the raw calls.
 */
export class FiduciaLockClient extends FiduciaClient {
  // --- locks ---------------------------------------------------------------

  /** Try to take the lock right now (wait:false). Returns null if it's held. */
  async tryLock(keyOrKeys: string | string[], opts: LockOptions = {}): Promise<Lock | null> {
    return this.acquireLock(normalize(keyOrKeys), false, opts);
  }

  /**
   * Block until the lock is acquired, the wait budget elapses
   * (`LockTimeoutError`), or the server errors. `wait:true`.
   */
  async lock(keyOrKeys: string | string[], opts: LockOptions = {}): Promise<Lock> {
    const lock = await this.acquireLock(normalize(keyOrKeys), true, opts);
    // acquireLock(wait=true) only returns null on a logic error; treat as timeout.
    if (!lock) throw new LockTimeoutError(normalize(keyOrKeys), opts.maxWaitTime ?? DEFAULT_MAX_WAIT);
    return lock;
  }

  /** Alias of `lock` — blocks until acquired (or throws). */
  async mustLock(keyOrKeys: string | string[], opts: LockOptions = {}): Promise<Lock> {
    return this.lock(keyOrKeys, opts);
  }

  /** Acquire, run `fn`, and always release (even if `fn` throws). */
  async withLock<T>(
    keyOrKeys: string | string[],
    opts: LockOptions,
    fn: (lock: Lock) => Promise<T> | T,
  ): Promise<T> {
    const lock = await this.lock(keyOrKeys, opts);
    try {
      return await fn(lock);
    } finally {
      try {
        await lock.unlock();
      } catch {
        /* best-effort release; the lease TTL is the backstop */
      }
    }
  }

  private async acquireLock(
    keys: string[],
    wait: boolean,
    opts: LockOptions,
  ): Promise<Lock | null> {
    const holder = opts.holder ?? genId();
    const ttl = opts.ttl ?? DEFAULT_TTL;

    const first = await this.lockAcquireMany(keys, { holder, ttl_ms: ttl, wait });
    const out = first?.result?.output ?? {};
    if (out.acquired) {
      return this.lockHandle(keys, holder, out.fencing_token, out.lease_expires_ms);
    }
    if (!wait) return null; // tryLock: held right now → fail fast

    // Queued (FIFO). Poll a member key until we've been promoted to holder.
    const deadline = Date.now() + (opts.maxWaitTime ?? DEFAULT_MAX_WAIT);
    const interval = opts.retryInterval ?? DEFAULT_RETRY_INTERVAL;
    const maxRetries = opts.maxRetries ?? Infinity;
    for (let attempt = 0; attempt < maxRetries; attempt++) {
      const remaining = deadline - Date.now();
      if (remaining <= 0) break;
      try {
        await sleep(Math.min(interval, remaining), opts.signal);
      } catch {
        throw new LockAbortedError(keys);
      }
      const got = await this.lockGet(keys[0]);
      const lock = got?.lock;
      if (lock && lock.holder === holder && lock.fencing_token != null) {
        return this.lockHandle(keys, holder, lock.fencing_token, lock.lease_expires_ms);
      }
    }
    throw new LockTimeoutError(keys, opts.maxWaitTime ?? DEFAULT_MAX_WAIT);
  }

  private lockHandle(
    keys: string[],
    holder: string,
    fencingToken: number,
    leaseExpiresMs?: number,
  ): Lock {
    return {
      keys,
      holder,
      fencingToken,
      leaseExpiresMs,
      unlock: () => this.lockRelease(holder, fencingToken),
      release: () => this.lockRelease(holder, fencingToken),
    };
  }

  // --- counting semaphores -------------------------------------------------

  /** Take a permit right now (wait:false). Returns null if at capacity. */
  async trySemaphore(
    key: string,
    limit: number,
    opts: LockOptions = {},
  ): Promise<SemaphoreHandle | null> {
    return this.acquireSemaphoreInner(key, limit, false, opts);
  }

  /** Block until a permit is free, the budget elapses, or the server errors. */
  async acquireSemaphore(
    key: string,
    limit: number,
    opts: LockOptions = {},
  ): Promise<SemaphoreHandle> {
    const h = await this.acquireSemaphoreInner(key, limit, true, opts);
    if (!h) throw new LockTimeoutError([key], opts.maxWaitTime ?? DEFAULT_MAX_WAIT);
    return h;
  }

  /** Acquire a permit, run `fn`, and always release. */
  async withSemaphore<T>(
    key: string,
    limit: number,
    opts: LockOptions,
    fn: (h: SemaphoreHandle) => Promise<T> | T,
  ): Promise<T> {
    const h = await this.acquireSemaphore(key, limit, opts);
    try {
      return await fn(h);
    } finally {
      try {
        await h.unlock();
      } catch {
        /* best-effort */
      }
    }
  }

  private async acquireSemaphoreInner(
    key: string,
    limit: number,
    wait: boolean,
    opts: LockOptions,
  ): Promise<SemaphoreHandle | null> {
    const holder = opts.holder ?? genId();
    const ttl = opts.ttl ?? DEFAULT_TTL;

    const first = await this.semaphoreAcquire(key, limit, { holder, ttl_ms: ttl, wait });
    const out = first?.result?.output ?? {};
    if (out.acquired) {
      return this.semaphoreHandle(key, holder, out.fencing_token, out.lease_expires_ms);
    }
    if (!wait) return null;

    const deadline = Date.now() + (opts.maxWaitTime ?? DEFAULT_MAX_WAIT);
    const interval = opts.retryInterval ?? DEFAULT_RETRY_INTERVAL;
    const maxRetries = opts.maxRetries ?? Infinity;
    for (let attempt = 0; attempt < maxRetries; attempt++) {
      const remaining = deadline - Date.now();
      if (remaining <= 0) break;
      try {
        await sleep(Math.min(interval, remaining), opts.signal);
      } catch {
        throw new LockAbortedError([key]);
      }
      const got = await this.semaphoreGet(key);
      const slot = (got?.semaphore?.holders ?? []).find((h: any) => h.holder === holder);
      if (slot && slot.fencing_token != null) {
        return this.semaphoreHandle(key, holder, slot.fencing_token, slot.lease_expires_ms);
      }
    }
    throw new LockTimeoutError([key], opts.maxWaitTime ?? DEFAULT_MAX_WAIT);
  }

  private semaphoreHandle(
    key: string,
    holder: string,
    fencingToken: number,
    leaseExpiresMs?: number,
  ): SemaphoreHandle {
    return {
      key,
      holder,
      fencingToken,
      leaseExpiresMs,
      unlock: () => this.semaphoreRelease(key, holder, fencingToken),
      release: () => this.semaphoreRelease(key, holder, fencingToken),
    };
  }
}

function normalize(keyOrKeys: string | string[]): string[] {
  return Array.isArray(keyOrKeys) ? keyOrKeys : [keyOrKeys];
}
