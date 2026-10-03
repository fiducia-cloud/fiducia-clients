import assert from "node:assert/strict";
import test from "node:test";

import { FiduciaLockClient, LockTimeoutError } from "./locking.ts";

type Call = { path: string; body: Record<string, any> };

function queuedFetch(calls: Call[]): typeof fetch {
  return (async (input: RequestInfo | URL, init: RequestInit = {}) => {
    const path = new URL(String(input)).pathname;
    const body = init.body ? JSON.parse(String(init.body)) : {};
    calls.push({ path, body });
    const output = path.endsWith("/cancel")
      ? { cancelled: true, acquired: false }
      : { acquired: false, queued: true };
    return new Response(JSON.stringify({ result: { output } }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }) as typeof fetch;
}

test("lock retries and cancellation reuse one attempt-scoped request id", async () => {
  const calls: Call[] = [];
  const client = new FiduciaLockClient("https://fiducia.test", { fetch: queuedFetch(calls) });

  await assert.rejects(
    () => client.lock("orders/42", {
      holder: "stable-worker",
      maxWaitTime: 50,
      retryInterval: 0,
      maxRetries: 1,
    }),
    LockTimeoutError,
  );

  const acquires = calls.filter((call) => call.path === "/v1/locks/acquire");
  const cancel = calls.find((call) => call.path === "/v1/locks/cancel");
  assert.equal(acquires.length, 2);
  assert.ok(cancel);
  assert.match(acquires[0].body.request_id, /^fdc-[0-9a-f-]{32,36}$/);
  assert.deepEqual(
    new Set([...acquires.map((call) => call.body.request_id), cancel.body.request_id]),
    new Set([acquires[0].body.request_id]),
  );
});

test("semaphore retries and cancellation reuse one attempt-scoped request id", async () => {
  const calls: Call[] = [];
  const client = new FiduciaLockClient("https://fiducia.test", { fetch: queuedFetch(calls) });

  await assert.rejects(
    () => client.acquireSemaphore("pool", 2, {
      holder: "stable-worker",
      maxWaitTime: 50,
      retryInterval: 0,
      maxRetries: 1,
    }),
    LockTimeoutError,
  );

  const acquires = calls.filter((call) => call.path === "/v1/semaphores/acquire");
  const cancel = calls.find((call) => call.path === "/v1/semaphores/cancel");
  assert.equal(acquires.length, 2);
  assert.ok(cancel);
  assert.deepEqual(
    new Set([...acquires.map((call) => call.body.request_id), cancel.body.request_id]),
    new Set([acquires[0].body.request_id]),
  );
});

test("initial renewed:false grants are token-renewed before handles return", async () => {
  const calls: Call[] = [];
  const transport = (async (input: RequestInfo | URL, init: RequestInit = {}) => {
    const path = new URL(String(input)).pathname;
    const body = init.body ? JSON.parse(String(init.body)) : {};
    calls.push({ path, body });
    const semaphore = path.includes("semaphores");
    const renew = path.endsWith("/renew");
    const token = semaphore ? 72 : 71;
    const output = renew
      ? { renewed: true, fencing_token: token, lease_expires_ms: semaphore ? 400 : 200 }
      : {
          acquired: true,
          queued: false,
          renewed: false,
          fencing_token: token,
          lease_expires_ms: semaphore ? 300 : 100,
        };
    return new Response(JSON.stringify({ result: { output } }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }) as typeof fetch;
  const client = new FiduciaLockClient("https://fiducia.test", { fetch: transport });

  const lock = await client.tryLock("orders/42", { holder: "stable-worker" });
  const permit = await client.trySemaphore("pool", 2, { holder: "stable-worker" });

  assert.equal(lock?.leaseExpiresMs, 200);
  assert.equal(permit?.leaseExpiresMs, 400);
  assert.deepEqual(calls.map((call) => call.path), [
    "/v1/locks/acquire",
    "/v1/locks/renew",
    "/v1/semaphores/acquire",
    "/v1/semaphores/renew",
  ]);
});

test("cancellation capacity exhaustion is surfaced as unsafe", async () => {
  const transport = (async (input: RequestInfo | URL) => {
    const path = new URL(String(input)).pathname;
    const output = path.endsWith("/cancel")
      ? { cancelled: false, acquired: false, reason: "cancellation_capacity" }
      : { acquired: false, queued: true };
    return new Response(JSON.stringify({ result: { output } }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }) as typeof fetch;
  const client = new FiduciaLockClient("https://fiducia.test", { fetch: transport });

  await assert.rejects(
    () => client.lock("orders/42", {
      holder: "stable-worker", maxWaitTime: 10, maxRetries: 0,
    }),
    /cancellation_capacity/,
  );
  await assert.rejects(
    () => client.acquireSemaphore("pool", 2, {
      holder: "stable-worker", maxWaitTime: 10, maxRetries: 0,
    }),
    /cancellation_capacity/,
  );
});
