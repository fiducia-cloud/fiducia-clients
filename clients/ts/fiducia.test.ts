import assert from "node:assert/strict";
import test from "node:test";

import { FiduciaClient } from "./fiducia.ts";

type RecordedCall = {
  method: string;
  path: string;
  body: unknown;
};

function recordingFetch(calls: RecordedCall[]): typeof fetch {
  return (async (input: RequestInfo | URL, init: RequestInit = {}) => {
    const url = new URL(String(input));
    const body = init.body === undefined ? undefined : JSON.parse(String(init.body));
    calls.push({
      method: init.method ?? "GET",
      path: `${url.pathname}${url.search}`,
      body,
    });
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
});
