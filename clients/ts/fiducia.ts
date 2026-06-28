// Fiducia HTTP client (TypeScript). Zero *runtime* dependency — uses the global
// `fetch` (Node 18+ or browsers). Implements PROTOCOL.md.
//
//   import { FiduciaClient } from "./fiducia";
//   import type { KvEntry, LockGrant } from "@fiducia/client";
//   const c = new FiduciaClient("https://api.fiducia.cloud");
//   const lock = await c.lockAcquire("orders/checkout", { holder: "worker-a", ttlMs: 30000 });
//   await c.lockRelease("orders/checkout", { holder: "worker-a", fencingToken: lock.result.fencing_token });

// Shared payload/error contract — re-exported from @fiducia/interfaces so callers
// type responses from one source of truth (these are type-only; no runtime cost).
export type {
  KvEntry,
  KvGetResponse,
  LockGrant,
  Leadership,
  ProposeError,
  ProposeOutcome,
  ServiceInstance,
  ServiceListResponse,
} from "@fiducia/interfaces/typescript";

export interface AcquireOpts { holder?: string; ttlMs?: number; wait?: boolean; max?: number; }
export interface AcquireManyOpts { keys: string[]; holder?: string; ttlMs?: number; wait?: boolean; }
export interface ReleaseOpts { holder: string; fencingToken: number; }
export interface RwOpts { ttlMs?: number; wait?: boolean; }
export interface KvPutOpts { ttlMs?: number; prevRevision?: number; }
export interface RateLimitCheckOpts {
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
export interface ScheduleUpsertOpts {
  cron?: string;
  oneShotAtMs?: number;
  target: ScheduleTarget;
  delivery?: "at_least_once" | "exactly_once";
  maxRetries?: number;
}
export interface WatchEvent<T = any> {
  event: string;
  data: T;
  id?: string;
}

export class FiduciaError extends Error {
  constructor(public status: number, public body: any) {
    super(`fiducia: HTTP ${status}`);
  }
}

const enc = encodeURIComponent;

export class FiduciaClient {
  private base: string;
  constructor(baseUrl: string) {
    this.base = baseUrl.replace(/\/+$/, "");
  }

  private async request(method: string, path: string, body?: unknown): Promise<any> {
    const res = await fetch(this.base + path, {
      method,
      headers: body !== undefined ? { "content-type": "application/json" } : undefined,
      body: body !== undefined ? JSON.stringify(body) : undefined,
    });
    const text = await res.text();
    const data = text ? JSON.parse(text) : null;
    if (!res.ok) throw new FiduciaError(res.status, data);
    return data;
  }

  private async *watch(path: string): AsyncGenerator<WatchEvent> {
    const res = await fetch(this.base + path, {
      method: "GET",
      headers: { accept: "text/event-stream" },
    });
    if (!res.ok) {
      const text = await res.text();
      const data = text ? JSON.parse(text) : null;
      throw new FiduciaError(res.status, data);
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
  }

  // --- misc ---
  health() { return this.request("GET", "/healthz"); }
  status() { return this.request("GET", "/v1/status"); }

  // --- locks ---
  lockGet(key: string) {
    return this.request("GET", `/v1/locks/${enc(key)}`);
  }
  lockAcquire(key: string, opts: AcquireOpts = {}) {
    return this.request("POST", `/v1/locks/${enc(key)}/acquire`,
      { holder: opts.holder, ttl_ms: opts.ttlMs, wait: opts.wait ?? false, max: opts.max });
  }
  lockAcquireMany(opts: AcquireManyOpts) {
    return this.request("POST", "/v1/locks/acquire-many",
      { keys: opts.keys, holder: opts.holder, ttl_ms: opts.ttlMs, wait: opts.wait ?? false });
  }
  lockRelease(key: string, opts: ReleaseOpts) {
    return this.request("POST", `/v1/locks/${enc(key)}/release`,
      { holder: opts.holder, fencing_token: opts.fencingToken });
  }
  lockReleaseMany(lockId: string) {
    return this.request("POST", "/v1/locks/release-many", { lock_id: lockId });
  }

  // --- semaphores ---
  semaphoreAcquire(key: string, opts: AcquireOpts = {}) {
    return this.request("POST", `/v1/semaphores/${enc(key)}/acquire`,
      { holder: opts.holder, ttl_ms: opts.ttlMs, wait: opts.wait ?? false, max: opts.max ?? 2 });
  }
  semaphoreRelease(key: string, opts: ReleaseOpts) {
    return this.request("POST", `/v1/semaphores/${enc(key)}/release`,
      { holder: opts.holder, fencing_token: opts.fencingToken });
  }

  // --- reader-writer locks ---
  rwAcquireRead(key: string, opts: RwOpts = {}) {
    return this.request("POST", `/v1/rw/${enc(key)}/read`, { ttl_ms: opts.ttlMs, wait: opts.wait ?? true });
  }
  rwEndRead(key: string, lockId: string) {
    return this.request("POST", `/v1/rw/${enc(key)}/read/end`, { lock_id: lockId });
  }
  rwAcquireWrite(key: string, opts: RwOpts = {}) {
    return this.request("POST", `/v1/rw/${enc(key)}/write`, { ttl_ms: opts.ttlMs, wait: opts.wait ?? true });
  }
  rwEndWrite(key: string, lockId: string) {
    return this.request("POST", `/v1/rw/${enc(key)}/write/end`, { lock_id: lockId });
  }

  // --- config KV ---
  kvGet(key: string) { return this.request("GET", `/v1/kv?key=${enc(key)}`); }
  kvPut(key: string, value: string, opts: KvPutOpts = {}) {
    return this.request("PUT", `/v1/kv?key=${enc(key)}`,
      { value, ttl_ms: opts.ttlMs, prev_revision: opts.prevRevision });
  }
  kvDelete(key: string) { return this.request("DELETE", `/v1/kv?key=${enc(key)}`); }
  kvList(prefix: string) { return this.request("GET", `/v1/kv?prefix=${enc(prefix)}`); }
  kvWatch(key: string) { return this.watch(`/v1/kv?key=${enc(key)}&watch=true`); }
  kvWatchPrefix(prefix: string) { return this.watch(`/v1/kv?prefix=${enc(prefix)}&watch=true`); }

  // --- rate limiting ---
  rateLimitCheck(tenant: string, key: string, opts: RateLimitCheckOpts) {
    return this.request("POST", `/v1/rate-limit/${enc(tenant)}/${enc(key)}/check`, {
      algorithm: opts.algorithm,
      limit: opts.limit,
      window_ms: opts.windowMs,
      refill_per_second: opts.refillPerSecond,
      cost: opts.cost,
    });
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
    });
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
  electionCampaign(name: string, candidate: string, ttlMs: number) {
    return this.request("POST", `/v1/elections/${enc(name)}/campaign`, { candidate, ttl_ms: ttlMs });
  }
  electionRenew(name: string, candidate: string, fencingToken: number) {
    return this.request("POST", `/v1/elections/${enc(name)}/renew`, { candidate, fencing_token: fencingToken });
  }
  electionResign(name: string, candidate: string, fencingToken: number) {
    return this.request("POST", `/v1/elections/${enc(name)}/resign`, { candidate, fencing_token: fencingToken });
  }
  electionGet(name: string) { return this.request("GET", `/v1/elections/${enc(name)}`); }
  electionWatch(name: string) { return this.watch(`/v1/elections/${enc(name)}/watch`); }

  // --- service discovery ---
  serviceRegister(service: string, instanceId: string, address: string, ttlMs: number) {
    return this.request("PUT", `/v1/services/${enc(service)}/instances/${enc(instanceId)}`,
      { address, ttl_ms: ttlMs });
  }
  serviceHeartbeat(service: string, instanceId: string) {
    return this.request("POST", `/v1/services/${enc(service)}/instances/${enc(instanceId)}/heartbeat`);
  }
  serviceDeregister(service: string, instanceId: string) {
    return this.request("DELETE", `/v1/services/${enc(service)}/instances/${enc(instanceId)}`);
  }
  serviceInstances(service: string) { return this.request("GET", `/v1/services/${enc(service)}`); }
  serviceList() { return this.request("GET", "/v1/services"); }
  serviceWatch(service: string) { return this.watch(`/v1/services/${enc(service)}/watch`); }
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
