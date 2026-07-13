// Unit tests for the generated Fiducia TypeScript client.
import assert from "node:assert/strict";
import test from "node:test";

import { FiduciaClient, FiduciaError } from "./fiducia.ts";

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

// A fetch that fails `failFirst` times (network error) before recording+succeeding.
function flakyFetch(calls: RecordedCall[], failFirst: number): typeof fetch {
  let seen = 0;
  return (async (input: RequestInfo | URL, init: RequestInit = {}) => {
    const url = new URL(String(input));
    const call: RecordedCall = {
      method: init.method ?? "GET",
      path: `${url.pathname}${url.search}`,
      body: init.body === undefined ? undefined : JSON.parse(String(init.body)),
    };
    const key = new Headers(init.headers).get("idempotency-key");
    if (key) call.idempotencyKey = key;
    calls.push(call);
    if (seen++ < failFirst) throw new TypeError("network down"); // retryable
    return new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }) as typeof fetch;
}

test("retried POST mutations pin one stable idempotency key across attempts", async () => {
  const calls: RecordedCall[] = [];
  const client = new FiduciaClient("https://fiducia.test", {
    fetch: flakyFetch(calls, 1),
    maxRetries: 2,
  });

  await client.tryLock("orders/42", { holder: "worker-a", ttlMs: 30_000 });

  // two attempts (first failed, second succeeded), both to the mutating route
  assert.equal(calls.length, 2);
  assert.equal(calls[0].method, "POST");
  assert.equal(calls[0].path, "/v1/locks/acquire");
  // both attempts carry a key, and it is the SAME key — so the server dedups the
  // committed-but-lost first attempt instead of granting a second acquire.
  assert.ok(calls[0].idempotencyKey, "first attempt must carry an idempotency key");
  assert.equal(calls[1].idempotencyKey, calls[0].idempotencyKey);
});

test("caller-supplied idempotency key is reused, not overwritten, on retry", async () => {
  const calls: RecordedCall[] = [];
  const client = new FiduciaClient("https://fiducia.test", {
    fetch: flakyFetch(calls, 1),
    maxRetries: 2,
  });

  await client.tryLock("orders/42", { holder: "worker-a", idempotencyKey: "caller_key_1" });
  assert.equal(calls.length, 2);
  assert.equal(calls[0].idempotencyKey, "caller_key_1");
  assert.equal(calls[1].idempotencyKey, "caller_key_1");
});

test("retried GET gets no injected idempotency key, and single-shot POST stays keyless", async () => {
  // GET is idempotent — no key needed even when retried.
  const getCalls: RecordedCall[] = [];
  const getClient = new FiduciaClient("https://fiducia.test", {
    fetch: flakyFetch(getCalls, 1),
    maxRetries: 2,
  });
  await getClient.lockGet("orders/42");
  assert.equal(getCalls.length, 2);
  assert.equal(getCalls[0].idempotencyKey, undefined);
  assert.equal(getCalls[1].idempotencyKey, undefined);

  // Retries disabled (default) — a single POST must not have behavior changed.
  const postCalls: RecordedCall[] = [];
  const postClient = new FiduciaClient("https://fiducia.test", { fetch: flakyFetch(postCalls, 0) });
  await postClient.tryLock("orders/42", { holder: "worker-a" });
  assert.equal(postCalls.length, 1);
  assert.equal(postCalls[0].idempotencyKey, undefined);
});

// A fetch that always answers with a redirect to an attacker-controlled host.
function redirectFetch(calls: RecordedCall[], status = 302): typeof fetch {
  return (async (input: RequestInfo | URL, init: RequestInit = {}) => {
    const url = new URL(String(input));
    calls.push({
      method: init.method ?? "GET",
      path: `${url.pathname}${url.search}`,
      body: init.body === undefined ? undefined : JSON.parse(String(init.body)),
    });
    // assert the client asked fetch not to auto-follow
    assert.equal(init.redirect, "manual");
    return new Response(null, { status, headers: { location: "https://evil.example/steal" } });
  }) as typeof fetch;
}

test("redirects are hard-rejected, not followed, and not retried", async () => {
  const calls: RecordedCall[] = [];
  const client = new FiduciaClient("https://fiducia.test", {
    fetch: redirectFetch(calls),
    maxRetries: 3, // even with retries on, a 3xx must not be retried
  });

  await assert.rejects(
    () => client.tryLock("orders/42", { holder: "worker-a", ttlMs: 30_000 }),
    (err: unknown) => {
      assert.ok(err instanceof FiduciaError);
      assert.equal(err.status, 302);
      assert.equal((err.body as any)?.error, "redirect_not_followed");
      assert.equal((err.body as any)?.location, "https://evil.example/steal");
      return true;
    },
  );
  // exactly one attempt — the redirect was neither followed nor retried
  assert.equal(calls.length, 1);
});

test("non-string metadata values are hard-rejected (query and body)", async () => {
  const calls: RecordedCall[] = [];
  const client = new FiduciaClient("https://fiducia.test", { fetch: recordingFetch(calls) });

  // bad input fails fast (synchronous throw), before any request is built
  assert.throws(
    () => client.serviceInstances("api", { region: 42 as unknown as string }),
    /metadata\["region"\] must be a string, got number/,
  );
  assert.throws(
    () => client.serviceRegister("api", "i-1", "10.0.0.1:80", 10_000, { tags: {} as unknown as string }),
    /metadata\["tags"\] must be a string, got object/,
  );
  // nothing left the client
  assert.equal(calls.length, 0);

  // valid string metadata still works
  await client.serviceInstances("api", { region: "us-east-1" });
  assert.equal(calls.pop()?.path, "/v1/services/api?metadata.region=us-east-1");
});

test("CRLF in an idempotency key is rejected before the request", async () => {
  const calls: RecordedCall[] = [];
  const client = new FiduciaClient("https://fiducia.test", { fetch: recordingFetch(calls) });
  await assert.rejects(
    () => client.tryLock("orders/42", { holder: "worker-a", idempotencyKey: "abc\r\nX-Injected: 1" }),
    /idempotency-key header value contains an illegal CR\/LF/,
  );
  assert.equal(calls.length, 0);
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

test("new coordination primitives remain layered onto the hardened transport", async () => {
  const calls: RecordedCall[] = [];
  const client = new FiduciaClient("https://fiducia.test", { fetch: recordingFetch(calls) });

  await client.counterAdd("orders/42", 2, { prevRevision: 7 });
  await client.barrierCreate("deploy", { kind: "quorum" }, { expected: 3 });
  await client.taskProgress("index", "worker-a", 9, { percent: 50 });
  await client.effectPrepare("charge", "payment", "payment-42", { requiredApprovals: 2 });
  await client.handoffOffer("handoff-1", "orders", "worker-a", "worker-b", 11);
  await client.decisionVote("release", "reviewer-a", { option: "ship", confidence: 0.9 });
  await client.budgetReserve("root/team", "reservation-1", "worker-a", { usd: 10 });
  await client.claimAssert("claim-1", "service", "healthy", "observer-a", { confidence: 0.8 });

  assert.deepEqual(calls.map((call) => call.path), [
    "/v1/counters/add",
    "/v1/barriers/create",
    "/v1/tasks/progress",
    "/v1/effects/prepare",
    "/v1/handoffs/offer",
    "/v1/decisions/vote",
    "/v1/budgets/reserve",
    "/v1/claims/assert",
  ]);
  assert.deepEqual(calls[0]?.body, {
    key: "orders/42",
    delta: 2,
    prev_revision: 7,
  });
  assert.deepEqual(calls[4]?.body, {
    name: "handoff-1",
    resource: "orders",
    from: "worker-a",
    to: "worker-b",
    from_token: 11,
  });
});
