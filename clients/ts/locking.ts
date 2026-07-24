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

import { FiduciaClient } from "./fiducia.ts";

type LockClientBase = new (
  ...args: ConstructorParameters<typeof FiduciaClient>
) => Omit<FiduciaClient, "tryLock" | "lock" | "mustLock" | "trySemaphore">;

// Runtime inheritance keeps the complete raw client surface. Omitting only the
// four names replaced by handle-oriented helpers prevents incompatible method
// overrides from erasing type safety for every other operation.
const FiduciaLockClientBase = FiduciaClient as unknown as LockClientBase;

/** Thrown by `lock`/`acquireSemaphore` when the wait budget elapses unacquired. */
export class LockTimeoutError extends Error {
  keys: string[];
  waitedMs: number;

  constructor(keys: string[], waitedMs: number) {
    super(`fiducia: timed out after ${waitedMs}ms waiting for lock on ${keys.join(", ")}`);
    this.name = "LockTimeoutError";
    this.keys = keys;
    this.waitedMs = waitedMs;
  }
}

/** Thrown when a wait is cancelled via an AbortSignal. */
export class LockAbortedError extends Error {
  keys: string[];

  constructor(keys: string[]) {
    super(`fiducia: lock wait aborted for ${keys.join(", ")}`);
    this.name = "LockAbortedError";
    this.keys = keys;
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
  /** Extend this exact fenced grant. Throws if authority has been lost. */
  renew(ttlMs?: number): Promise<any>;
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
  /** Extend this exact fenced permit. Throws if authority has been lost. */
  renew(ttlMs?: number): Promise<any>;
  unlock(): Promise<any>;
  release(): Promise<any>;
}

const DEFAULT_TTL = 60_000;
const DEFAULT_MAX_WAIT = 30_000;
const DEFAULT_RETRY_INTERVAL = 250;

function genId(): string {
  const cryptoApi = globalThis.crypto;
  if (cryptoApi?.randomUUID) return `fdc-${cryptoApi.randomUUID()}`;
  if (cryptoApi?.getRandomValues) {
    const bytes = new Uint8Array(16);
    cryptoApi.getRandomValues(bytes);
    return `fdc-${Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
  }
  throw new Error("fiducia: secure randomness is unavailable; provide an explicit nonempty holder");
}

function fencingToken(output: any, primitive: string): number {
  const token = output?.fencing_token;
  if (!Number.isSafeInteger(token) || token <= 0) {
    throw new Error(`fiducia: acquired ${primitive} carried no valid fencing token`);
  }
  return token;
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
export class FiduciaLockClient extends FiduciaLockClientBase {
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
    const holder = opts.holder?.trim() || genId();
    const requestId = genId();
    const ttl = opts.ttl ?? DEFAULT_TTL;

    const maxWait = opts.maxWaitTime ?? DEFAULT_MAX_WAIT;
    let first: any;
    try {
      first = await this.lockAcquireMany({
        keys,
        holder,
        requestId,
        ttlMs: ttl,
        wait,
        waitTimeoutMs: wait ? maxWait : undefined,
      });
    } catch (error) {
      // The request may have committed even when its response was lost. Cancel
      // the identity and release any raced grant before surfacing ambiguity.
      await this.cancelLockWait(keys, holder, requestId);
      throw error;
    }
    const out = first?.result?.output ?? {};
    if (out.acquired) {
      const token = fencingToken(out, "lock");
      if (out.renewed === false) {
        try {
          const renewed = await this.lockRenew(keys, holder, token, ttl);
          const renewedOut = renewed?.result?.output ?? {};
          if (!renewedOut.renewed) {
            throw new Error("fiducia: reacquired lock lost fenced authority during renewal");
          }
          return this.lockHandle(keys, holder, token, renewedOut.lease_expires_ms, ttl);
        } catch (error) {
          await this.cancelLockWait(keys, holder, requestId);
          throw error;
        }
      }
      return this.lockHandle(keys, holder, token, out.lease_expires_ms, ttl);
    }
    if (!wait) return null; // tryLock: held right now → fail fast

    // Re-submit the exact queued identity with bounded backoff. A committed
    // retry advances expiry/promotion in the Raft state machine, while queue
    // dedup preserves the original FIFO position.
    const deadline = Date.now() + maxWait;
    const interval = opts.retryInterval ?? DEFAULT_RETRY_INTERVAL;
    const maxRetries = opts.maxRetries ?? Infinity;
    let acquired = false;
    try {
      for (let attempt = 0; attempt < maxRetries; attempt++) {
        const remaining = deadline - Date.now();
        if (remaining <= 0) break;
        try {
          const delay = Math.min(interval * (2 ** Math.min(attempt, 3)), 2_000, remaining);
          await sleep(delay, opts.signal);
        } catch {
          throw new LockAbortedError(keys);
        }
        const retried = await this.lockAcquireMany({
          keys,
          holder,
          requestId,
          ttlMs: ttl,
          wait: true,
          waitTimeoutMs: maxWait,
        });
        const retryOut = retried?.result?.output ?? {};
        if (retryOut.acquired) {
          const token = fencingToken(retryOut, "lock");
          const renewed = await this.lockRenew(keys, holder, token, ttl);
          const renewedOut = renewed?.result?.output ?? {};
          if (!renewedOut.renewed) {
            throw new Error("fiducia: retry-discovered lock lost fenced authority during renewal");
          }
          acquired = true;
          return this.lockHandle(
            keys,
            holder,
            token,
            renewedOut.lease_expires_ms,
            ttl,
          );
        }
      }
      throw new LockTimeoutError(keys, maxWait);
    } finally {
      if (!acquired) await this.cancelLockWait(keys, holder, requestId);
    }
  }

  private lockHandle(
    keys: string[],
    holder: string,
    fencingToken: number,
    leaseExpiresMs?: number,
    defaultTtlMs: number = DEFAULT_TTL,
  ): Lock {
    let currentTtlMs = defaultTtlMs;
    const handle: Lock = {
      keys,
      holder,
      fencingToken,
      leaseExpiresMs,
      renew: async (ttlMs = currentTtlMs) => {
        const response = await this.lockRenew(keys, holder, fencingToken, ttlMs);
        const output = response?.result?.output ?? {};
        if (!output.renewed) throw new Error("fiducia: lock renewal lost fenced authority");
        handle.leaseExpiresMs = output.lease_expires_ms;
        currentTtlMs = ttlMs;
        return response;
      },
      unlock: () => this.lockRelease(keys[0], { holder, fencingToken }),
      release: () => this.lockRelease(keys[0], { holder, fencingToken }),
    };
    return handle;
  }

  private async cancelLockWait(keys: string[], holder: string, requestId: string): Promise<void> {
    const response = await this.lockCancel(keys, holder, { requestId });
    const output = response?.result?.output ?? {};
    if (output.acquired && output.fencing_token != null) {
      const released = await this.lockRelease(keys[0], {
        holder,
        fencingToken: fencingToken(output, "raced lock"),
      });
      if (released?.result?.output?.released === false) {
        throw new Error("fiducia: raced lock could not be released safely");
      }
      return;
    }
    if (output.cancelled === true) return;
    throw new Error(
      `fiducia: lock cancellation did not establish safety (${String(output.reason ?? "invalid_response")})`,
    );
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
    const holder = opts.holder?.trim() || genId();
    const requestId = genId();
    const ttl = opts.ttl ?? DEFAULT_TTL;

    const maxWait = opts.maxWaitTime ?? DEFAULT_MAX_WAIT;
    let first: any;
    try {
      first = await this.semaphoreAcquire(key, {
        max: limit,
        holder,
        requestId,
        ttlMs: ttl,
        wait,
        waitTimeoutMs: wait ? maxWait : undefined,
      });
    } catch (error) {
      await this.cancelSemaphoreWait(key, holder, requestId);
      throw error;
    }
    const out = first?.result?.output ?? {};
    if (out.acquired) {
      const token = fencingToken(out, "semaphore permit");
      if (out.renewed === false) {
        try {
          const renewed = await this.semaphoreRenew(key, holder, token, ttl);
          const renewedOut = renewed?.result?.output ?? {};
          if (!renewedOut.renewed) {
            throw new Error(
              "fiducia: reacquired semaphore permit lost fenced authority during renewal",
            );
          }
          return this.semaphoreHandle(
            key,
            holder,
            token,
            renewedOut.lease_expires_ms,
            ttl,
          );
        } catch (error) {
          await this.cancelSemaphoreWait(key, holder, requestId);
          throw error;
        }
      }
      return this.semaphoreHandle(
        key,
        holder,
        token,
        out.lease_expires_ms,
        ttl,
      );
    }
    if (out.reason === "limit_mismatch") {
      throw new Error(
        `fiducia: semaphore limit mismatch (requested ${limit}, configured ${String(out.limit)})`,
      );
    }
    if (!wait) return null;

    const deadline = Date.now() + maxWait;
    const interval = opts.retryInterval ?? DEFAULT_RETRY_INTERVAL;
    const maxRetries = opts.maxRetries ?? Infinity;
    let acquired = false;
    try {
      for (let attempt = 0; attempt < maxRetries; attempt++) {
        const remaining = deadline - Date.now();
        if (remaining <= 0) break;
        try {
          const delay = Math.min(interval * (2 ** Math.min(attempt, 3)), 2_000, remaining);
          await sleep(delay, opts.signal);
        } catch {
          throw new LockAbortedError([key]);
        }
        const retried = await this.semaphoreAcquire(key, {
          max: limit,
          holder,
          requestId,
          ttlMs: ttl,
          wait: true,
          waitTimeoutMs: maxWait,
        });
        const retryOut = retried?.result?.output ?? {};
        if (retryOut.acquired) {
          const token = fencingToken(retryOut, "semaphore permit");
          const renewed = await this.semaphoreRenew(key, holder, token, ttl);
          const renewedOut = renewed?.result?.output ?? {};
          if (!renewedOut.renewed) {
            throw new Error(
              "fiducia: retry-discovered semaphore permit lost fenced authority during renewal",
            );
          }
          acquired = true;
          return this.semaphoreHandle(
            key,
            holder,
            token,
            renewedOut.lease_expires_ms,
            ttl,
          );
        }
        if (retryOut.reason === "limit_mismatch") {
          throw new Error(
            `fiducia: semaphore limit mismatch (requested ${limit}, configured ${String(retryOut.limit)})`,
          );
        }
      }
      throw new LockTimeoutError([key], maxWait);
    } finally {
      if (!acquired) await this.cancelSemaphoreWait(key, holder, requestId);
    }
  }

  private semaphoreHandle(
    key: string,
    holder: string,
    fencingToken: number,
    leaseExpiresMs?: number,
    defaultTtlMs: number = DEFAULT_TTL,
  ): SemaphoreHandle {
    let currentTtlMs = defaultTtlMs;
    const handle: SemaphoreHandle = {
      key,
      holder,
      fencingToken,
      leaseExpiresMs,
      renew: async (ttlMs = currentTtlMs) => {
        const response = await this.semaphoreRenew(key, holder, fencingToken, ttlMs);
        const output = response?.result?.output ?? {};
        if (!output.renewed) throw new Error("fiducia: semaphore renewal lost fenced authority");
        handle.leaseExpiresMs = output.lease_expires_ms;
        currentTtlMs = ttlMs;
        return response;
      },
      unlock: () => this.semaphoreRelease(key, { holder, fencingToken }),
      release: () => this.semaphoreRelease(key, { holder, fencingToken }),
    };
    return handle;
  }

  private async cancelSemaphoreWait(key: string, holder: string, requestId: string): Promise<void> {
    const response = await this.semaphoreCancel(key, holder, { requestId });
    const output = response?.result?.output ?? {};
    if (output.acquired && output.fencing_token != null) {
      const released = await this.semaphoreRelease(key, {
        holder,
        fencingToken: fencingToken(output, "raced semaphore permit"),
      });
      if (released?.result?.output?.released === false) {
        throw new Error("fiducia: raced semaphore permit could not be released safely");
      }
      return;
    }
    if (output.cancelled === true) return;
    throw new Error(
      `fiducia: semaphore cancellation did not establish safety (${String(output.reason ?? "invalid_response")})`,
    );
  }
}

function normalize(keyOrKeys: string | string[]): string[] {
  return Array.isArray(keyOrKeys) ? keyOrKeys : [keyOrKeys];
}
