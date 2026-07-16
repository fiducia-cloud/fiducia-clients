// Unit tests for the generated Fiducia TypeScript client.
import assert from "node:assert/strict";
import test from "node:test";

import { FiduciaClient, FiduciaError, FiduciaTimeoutError } from "./fiducia.ts";

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

test("keyless POST mutations are not retried", async () => {
  const calls: RecordedCall[] = [];
  const client = new FiduciaClient("https://fiducia.test", {
    fetch: flakyFetch(calls, 1),
    maxRetries: 2,
  });

  await assert.rejects(
    () => client.tryLock("orders/42", { holder: "worker-a", ttlMs: 30_000 }),
    TypeError,
  );

  // A generated header would falsely imply safety at a direct node, which does
  // not consume the hosted gateway's customer replay key.
  assert.equal(calls.length, 1);
  assert.equal(calls[0].method, "POST");
  assert.equal(calls[0].path, "/v1/locks/acquire");
  assert.equal(calls[0].idempotencyKey, undefined);
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

// A fetch that answers not-leader (503 + ProposeError-shaped body) `failFirst`
// times, then succeeds — the shape a node returns when the shard leader moved.
function notLeaderFetch(calls: RecordedCall[], failFirst: number): typeof fetch {
  let seen = 0;
  return (async (input: RequestInfo | URL, init: RequestInit = {}) => {
    const url = new URL(String(input));
    calls.push({
      method: init.method ?? "GET",
      path: `${url.pathname}${url.search}`,
      body: init.body === undefined ? undefined : JSON.parse(String(init.body)),
    });
    if (seen++ < failFirst) {
      return new Response(
        JSON.stringify({ error: { reason: "not_leader", message: "shard 3 leader moved" } }),
        { status: 503, headers: { "content-type": "application/json" } },
      );
    }
    return new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }) as typeof fetch;
}

test("not-leader responses surface status and parsed body per PROTOCOL.md", async () => {
  // Contract (PROTOCOL.md Errors): surface the status code and parsed body;
  // do not retry by default — the edge/LB handles leader redirects.
  const calls: RecordedCall[] = [];
  const client = new FiduciaClient("https://fiducia.test", {
    fetch: notLeaderFetch(calls, Number.POSITIVE_INFINITY),
  });

  await assert.rejects(
    () => client.tryLock("orders/42", { holder: "worker-a", ttlMs: 30_000 }),
    (err: unknown) => {
      assert.ok(err instanceof FiduciaError);
      assert.equal(err.status, 503);
      assert.equal((err.body as any)?.error?.reason, "not_leader");
      assert.equal((err.body as any)?.error?.message, "shard 3 leader moved");
      return true;
    },
  );
  assert.equal(calls.length, 1); // surfaced, not silently retried or followed

  // With retries opted in, a 503 IS retryable for idempotent reads: the next
  // attempt lands on the new leader and succeeds.
  const retryCalls: RecordedCall[] = [];
  const retryClient = new FiduciaClient("https://fiducia.test", {
    fetch: notLeaderFetch(retryCalls, 1),
    maxRetries: 2,
  });
  assert.deepEqual(await retryClient.lockGet("orders/42"), { ok: true });
  assert.equal(retryCalls.length, 2);
  assert.equal(retryCalls[0].path, "/v1/locks?key=orders%2F42");
  assert.equal(retryCalls[1].path, "/v1/locks?key=orders%2F42");
});

// A fetch that never answers but honors AbortSignal, like a hung connection.
function hangingFetch(calls: RecordedCall[]): typeof fetch {
  return (async (input: RequestInfo | URL, init: RequestInit = {}) => {
    const url = new URL(String(input));
    calls.push({
      method: init.method ?? "GET",
      path: `${url.pathname}${url.search}`,
      body: init.body === undefined ? undefined : JSON.parse(String(init.body)),
    });
    return new Promise<Response>((_resolve, reject) => {
      init.signal?.addEventListener(
        "abort",
        () => reject(Object.assign(new Error("aborted"), { name: "AbortError" })),
        { once: true },
      );
    });
  }) as typeof fetch;
}

test("request timeout aborts a hung request and surfaces FiduciaTimeoutError", async () => {
  const calls: RecordedCall[] = [];
  const client = new FiduciaClient("https://fiducia.test", {
    fetch: hangingFetch(calls),
    timeoutMs: 25,
    maxRetries: 1, // timeouts are retryable for idempotent reads
  });

  await assert.rejects(
    () => client.lockGet("orders/42"),
    (err: unknown) => {
      assert.ok(err instanceof FiduciaTimeoutError);
      assert.equal(err.name, "FiduciaTimeoutError");
      assert.equal(err.timeoutMs, 25);
      assert.equal(err.method, "GET");
      assert.equal(err.path, "/v1/locks?key=orders%2F42");
      assert.equal(err.attempt, 2); // the retry also timed out; attempts counted
      return true;
    },
  );
  assert.equal(calls.length, 2); // initial attempt + one retry, then surfaced

  // A hung keyless POST must NOT be retried after its timeout: replaying a
  // lock acquire could double-grant. One attempt, then the timeout surfaces.
  const postCalls: RecordedCall[] = [];
  const postClient = new FiduciaClient("https://fiducia.test", {
    fetch: hangingFetch(postCalls),
    timeoutMs: 25,
    maxRetries: 3,
  });
  await assert.rejects(
    () => postClient.tryLock("orders/42", { holder: "worker-a" }),
    (err: unknown) => err instanceof FiduciaTimeoutError && err.attempt === 1,
  );
  assert.equal(postCalls.length, 1);
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
