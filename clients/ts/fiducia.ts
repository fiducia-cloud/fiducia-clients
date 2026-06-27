// Fiducia HTTP client (TypeScript). Zero *runtime* dependency — uses the global
// `fetch` (Node 18+ or browsers). Implements PROTOCOL.md.
//
//   import { FiduciaClient } from "./fiducia";
//   import type { KvEntry, LockGrant } from "@fiducia/client";
//   const c = new FiduciaClient("https://api.fiducia.cloud");
//   const lock = await c.lockAcquire("orders/checkout", { ttlMs: 30000 });
//   await c.lockRelease("orders/checkout", lock.lock_id);

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

export interface AcquireOpts { ttlMs?: number; wait?: boolean; max?: number; }
export interface RwOpts { ttlMs?: number; wait?: boolean; }
export interface KvPutOpts { ttlMs?: number; }

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

  // --- misc ---
  health() { return this.request("GET", "/healthz"); }
  status() { return this.request("GET", "/v1/status"); }

  // --- locks & semaphores ---
  lockAcquire(key: string, opts: AcquireOpts = {}) {
    return this.request("POST", `/v1/locks/${enc(key)}/acquire`,
      { ttl_ms: opts.ttlMs, wait: opts.wait ?? true, max: opts.max ?? 1 });
  }
  lockRelease(key: string, lockId: string) {
    return this.request("POST", `/v1/locks/${enc(key)}/release`, { lock_id: lockId });
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
  kvGet(key: string) { return this.request("GET", `/v1/kv/${enc(key)}`); }
  kvPut(key: string, value: string, opts: KvPutOpts = {}) {
    return this.request("PUT", `/v1/kv/${enc(key)}`, { value, ttl_ms: opts.ttlMs });
  }
  kvDelete(key: string) { return this.request("DELETE", `/v1/kv/${enc(key)}`); }
  kvList(prefix: string) { return this.request("GET", `/v1/kv?prefix=${enc(prefix)}`); }

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
}
