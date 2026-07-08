import assert from "node:assert/strict";
import test from "node:test";

import { FiduciaClient } from "./fiducia.ts";

type RecordedCall = {
  method: string;
  path: string;
  body: unknown;
  idempotencyKey?: string;
};

function recordingFetch(calls: RecordedCall[]): typeof fetch {
  return (async (input: RequestInfo | URL, init: RequestInit = {}) => {
    const url = new URL(String(input));
    const body = init.body === undefined ? undefined : JSON.parse(String(init.body));
    const call: RecordedCall = {
      method: init.method ?? "GET",
      path: `${url.pathname}${url.search}`,
      body,
    };
    const idempotencyKey = new Headers(init.headers).get("idempotency-key");
    if (idempotencyKey) call.idempotencyKey = idempotencyKey;
    calls.push(call);
    return new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }) as typeof fetch;
}

test("coordination SDK methods hide slash-safe wire routes", async () => {
  const calls: RecordedCall[] = [];
  const client = new FiduciaClient("https://fiducia.test", { fetch: recordingFetch(calls) });

  await client.lockGet("orders/42");
  assert.deepEqual(calls.pop(), {
    method: "GET",
    path: "/v1/locks?key=orders%2F42",
    body: undefined,
  });

  await client.tryLock("orders/42", { holder: "worker-a", ttlMs: 30_000 });
  assert.deepEqual(calls.pop(), {
    method: "POST",
    path: "/v1/locks/acquire",
    body: { key: "orders/42", holder: "worker-a", ttl_ms: 30_000, wait: false },
  });

  await client.mustLockMany({ keys: ["orders/42", "inventory/sku-7"], holder: "worker-a" });
  assert.deepEqual(calls.pop(), {
    method: "POST",
    path: "/v1/locks/acquire",
    body: { keys: ["orders/42", "inventory/sku-7"], holder: "worker-a", wait: true },
  });

  await client.lockRelease("orders/42", { holder: "worker-a", fencingToken: 11 });
  assert.deepEqual(calls.pop(), {
    method: "POST",
    path: "/v1/locks/release",
    body: { holder: "worker-a", fencing_token: 11 },
  });

  assert.throws(() => client.lockReleaseMany("legacy-lock-id"), /legacy/);

  await client.semaphoreGet("pools/db/primary");
  assert.deepEqual(calls.pop(), {
    method: "GET",
    path: "/v1/semaphores?key=pools%2Fdb%2Fprimary",
    body: undefined,
  });

  await client.trySemaphore("pools/db/primary", { holder: "worker-b", max: 3 });
  assert.deepEqual(calls.pop(), {
    method: "POST",
    path: "/v1/semaphores/acquire",
    body: { key: "pools/db/primary", holder: "worker-b", wait: false, limit: 3 },
  });

  await client.semaphoreRelease("pools/db/primary", { holder: "worker-b", fencingToken: 12 });
  assert.deepEqual(calls.pop(), {
    method: "POST",
    path: "/v1/semaphores/release",
    body: { key: "pools/db/primary", holder: "worker-b", fencing_token: 12 },
  });

  await client.electionCampaign("prod/invoice-reconciler/leader", "pod-a", 15_000, {
    metadata: { region: "us-east-1", address: "10.2.4.18:8080" },
  });
  assert.deepEqual(calls.pop(), {
    method: "POST",
    path: "/v1/elections/prod%2Finvoice-reconciler%2Fleader/campaign",
    body: {
      candidate: "pod-a",
      ttl_ms: 15_000,
      metadata: { region: "us-east-1", address: "10.2.4.18:8080" },
    },
  });
});

test("service discovery sends required heartbeat body and metadata", async () => {
  const calls: RecordedCall[] = [];
  const client = new FiduciaClient("https://fiducia.test", { fetch: recordingFetch(calls) });

  await client.serviceRegister("api", "i-1", "10.0.0.1:9000", 10_000, { region: "eu-central-1" });
  assert.deepEqual(calls.pop(), {
    method: "PUT",
    path: "/v1/services/api/instances/i-1",
    body: { address: "10.0.0.1:9000", ttl_ms: 10_000, metadata: { region: "eu-central-1" } },
  });

  await client.serviceHeartbeat("api", "i-1");
  assert.deepEqual(calls.pop(), {
    method: "POST",
    path: "/v1/services/api/instances/i-1/heartbeat",
    body: {},
  });

  await client.serviceInstances("api", { region: "eu central", version: "blue/1" });
  assert.deepEqual(calls.pop(), {
    method: "GET",
    path: "/v1/services/api?metadata.region=eu+central&metadata.version=blue%2F1",
    body: undefined,
  });
});

test("mutating request controls can send an Idempotency-Key header", async () => {
  const calls: RecordedCall[] = [];
  const client = new FiduciaClient("https://fiducia.test", { fetch: recordingFetch(calls) });

  await client.kvPut("orders/42", "paid", { ttlMs: 30_000, idempotencyKey: "req_order_42" });
  assert.deepEqual(calls.pop(), {
    method: "PUT",
    path: "/v1/kv?key=orders%2F42",
    body: { value: "paid", ttl_ms: 30_000 },
    idempotencyKey: "req_order_42",
  });

  await client.tryLock("orders/42", { holder: "worker-a", idempotencyKey: "lock_req_1" });
  assert.deepEqual(calls.pop(), {
    method: "POST",
    path: "/v1/locks/acquire",
    body: { key: "orders/42", holder: "worker-a", wait: false },
    idempotencyKey: "lock_req_1",
  });
});

test("idempotency helpers use slash-safe routes and canonical bodies", async () => {
  const calls: RecordedCall[] = [];
  const client = new FiduciaClient("https://fiducia.test", { fetch: recordingFetch(calls) });

  await client.idempotencyGet("stripe-webhook/event_123");
  assert.deepEqual(calls.pop(), {
    method: "GET",
    path: "/v1/idempotency?key=stripe-webhook%2Fevent_123",
    body: undefined,
  });

  await client.idempotencyClaim("stripe-webhook/event_123", {
    owner: "worker-a",
    ttl: "24h",
    metadata: { source: "stripe" },
  });
  assert.deepEqual(calls.pop(), {
    method: "POST",
    path: "/v1/idempotency/claim",
    body: {
      key: "stripe-webhook/event_123",
      owner: "worker-a",
      ttl: "24h",
      metadata: { source: "stripe" },
    },
  });

  await client.idempotencyComplete("stripe-webhook/event_123", {
    owner: "worker-a",
    fencingToken: 11,
    result: { status: "ok" },
  });
  assert.deepEqual(calls.pop(), {
    method: "POST",
    path: "/v1/idempotency/complete",
    body: {
      key: "stripe-webhook/event_123",
      owner: "worker-a",
      fencing_token: 11,
      result: { status: "ok" },
    },
  });
});

test("idempotency request option stays in headers for idempotency primitives", async () => {
  const calls: RecordedCall[] = [];
  const client = new FiduciaClient("https://fiducia.test", { fetch: recordingFetch(calls) });

  await client.idempotencyClaim("webhook/event_456", {
    owner: "worker-a",
    idempotencyKey: "claim_req_456",
  });
  assert.deepEqual(calls.pop(), {
    method: "POST",
    path: "/v1/idempotency/claim",
    body: { key: "webhook/event_456", owner: "worker-a" },
    idempotencyKey: "claim_req_456",
  });

  await client.scheduleUpsert("nightly", {
    cron: "0 0 * * *",
    target: { kind: "webhook", url: "https://example.test/hook" },
    idempotencyKey: "schedule_req_1",
  });
  assert.deepEqual(calls.pop(), {
    method: "PUT",
    path: "/v1/cron/schedules/nightly",
    body: {
      cron: "0 0 * * *",
      target: { kind: "webhook", url: "https://example.test/hook" },
    },
    idempotencyKey: "schedule_req_1",
  });
});

test("request controls reject invalid timeout and retry values", () => {
  assert.throws(
    () => new FiduciaClient("https://fiducia.test", { timeoutMs: 0 }),
    /timeout/,
  );
  assert.throws(
    () => new FiduciaClient("https://fiducia.test", { retries: -1 }),
    /retries/,
  );
  assert.throws(
    () => new FiduciaClient("https://fiducia.test", { retryDelayMs: -1 }),
    /retryDelayMs/,
  );
});
