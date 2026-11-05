import assert from "node:assert/strict";
import { once } from "node:events";
import { createServer } from "node:http";
import test from "node:test";

import { FiduciaClient, FiduciaError } from "./fiducia.ts";

// Exercises the published SDK over actual loopback sockets. These tests do
// not replace the cluster-backed certifier; they catch wire/retry regressions
// before any real cluster or customer credentials are needed.
async function serve(handler) {
  const server = createServer((request, response) => {
    Promise.resolve(handler(request, response)).catch(() => {
      if (!response.headersSent) response.writeHead(500);
      response.end("local_fixture_error");
    });
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  return {
    url: `http://127.0.0.1:${server.address().port}`,
    close: () => new Promise((resolve, reject) =>
      server.close((error) => error ? reject(error) : resolve()),
    ),
  };
}

async function readBody(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8");
}

function json(response, status, payload, extraHeaders = {}) {
  response.writeHead(status, { "content-type": "application/json", ...extraHeaders });
  response.end(JSON.stringify(payload));
}

test("SDK -> HTTP server: encoded KV paths and typed write body survive a socket hop", async (t) => {
  const calls = [];
  const api = await serve(async (request, response) => {
    calls.push({
      method: request.method,
      path: request.url,
      body: await readBody(request),
    });
    json(response, 200, { committed: true, result: { output: { revision: 17 } } });
  });
  t.after(api.close);
  const client = new FiduciaClient(api.url);
  const result = await client.kvPut("team/a key", "some value", {
    prevRevision: 16,
    plaintext: false,
    idempotencyKey: "customer-put-1",
  });
  assert.equal(result.result.output.revision, 17);
  assert.deepEqual(calls, [{
    method: "PUT",
    path: "/v1/kv?key=team%2Fa%20key",
    body: JSON.stringify({
      value: "some value",
      prev_revision: 16,
      plaintext: false,
    }),
  }]);
});

test("SDK -> HTTP server: POST after HTTP 503 never retries without replay authorization", async (t) => {
  const attempts = [];
  const api = await serve(async (request, response) => {
    attempts.push({
      path: request.url,
      idempotencyKey: request.headers["idempotency-key"],
      payload: JSON.parse(await readBody(request)),
    });
    json(response, 503, { error: "ambiguous_gateway_failure" });
  });
  t.after(api.close);
  const client = new FiduciaClient(api.url, { maxRetries: 3 });
  await assert.rejects(
    () => client.tryLock("orders/42", {
      holder: "worker-a",
      requestId: "attempt-42",
      ttlMs: 30_000,
    }),
    (error) => error instanceof FiduciaError && error.status === 503,
  );
  assert.equal(attempts.length, 1);
  assert.equal(attempts[0].path, "/v1/locks/acquire");
  assert.equal(attempts[0].idempotencyKey, undefined);
  assert.equal(attempts[0].payload.request_id, "attempt-42");
});

test("SDK -> HTTP server: keyed retry reuses the exact logical acquire attempt", async (t) => {
  const attempts = [];
  const api = await serve(async (request, response) => {
    attempts.push({
      method: request.method,
      path: request.url,
      idempotencyKey: request.headers["idempotency-key"],
      payload: JSON.parse(await readBody(request)),
    });
    if (attempts.length === 1) {
      json(response, 503, { error: "gateway_retryable" });
    } else {
      json(response, 200, {
        committed: true,
        result: { output: { acquired: true, fencing_token: 23 } },
      });
    }
  });
  t.after(api.close);
  const client = new FiduciaClient(api.url, { maxRetries: 1 });
  const result = await client.tryLock("orders/42", {
    holder: "worker-b",
    requestId: "attempt-43",
    idempotencyKey: "customer-acquire-43",
  });
  assert.equal(result.result.output.fencing_token, 23);
  assert.equal(attempts.length, 2);
  assert.deepEqual(attempts[1], attempts[0], "retry must not change request identity");
  assert.equal(attempts[0].method, "POST");
  assert.equal(attempts[0].path, "/v1/locks/acquire");
  assert.equal(attempts[0].idempotencyKey, "customer-acquire-43");
  assert.equal(attempts[0].payload.request_id, "attempt-43");
});

test("SDK -> HTTP server: follower not_leader rejection can be safely retried without a key", async (t) => {
  let requests = 0;
  const api = await serve(async (request, response) => {
    await readBody(request);
    requests++;
    if (requests === 1) {
      json(response, 503, { error: { reason: "not_leader", retryable: true } }, {
        "x-fiducia-not-leader": "true",
      });
    } else {
      json(response, 200, {
        committed: true,
        result: { output: { acquired: true, fencing_token: 27 } },
      });
    }
  });
  t.after(api.close);
  const client = new FiduciaClient(api.url, { maxRetries: 1 });
  const result = await client.tryLock("leader/42", {
    holder: "worker-c", requestId: "attempt-44",
  });
  assert.equal(result.result.output.fencing_token, 27);
  assert.equal(requests, 2);
});

test("SDK -> HTTP server: redirect cannot forward mutation or idempotency key to another origin", async (t) => {
  let stolenRequests = 0;
  const attacker = await serve(async (_request, response) => {
    stolenRequests++;
    json(response, 200, { attackerReceivedRequest: true });
  });
  t.after(attacker.close);
  let originRequests = 0;
  const api = await serve(async (request, response) => {
    await readBody(request);
    originRequests++;
    response.writeHead(307, { location: `${attacker.url}/capture` });
    response.end();
  });
  t.after(api.close);
  const client = new FiduciaClient(api.url, { maxRetries: 2 });
  await assert.rejects(
    () => client.tryLock("sensitive", {
      holder: "worker-d",
      idempotencyKey: "secret-replay-key",
    }),
    (error) => error instanceof FiduciaError && error.body?.error === "redirect_not_followed",
  );
  assert.equal(originRequests, 1);
  assert.equal(stolenRequests, 0);
});

test("SDK rejects unsafe fencing tokens returned by a real HTTP server", async (t) => {
  const api = await serve(async (_request, response) => {
    json(response, 200, {
      committed: true,
      result: { output: { acquired: true, fencing_token: 9007199254740992 } },
    });
  });
  t.after(api.close);
  const client = new FiduciaClient(api.url);
  await assert.rejects(() => client.lockGet("unsafe/token"), /safe integer/);
});


test("SDK -> node: a lost POST response is retried only with a durable replay key", async (t) => {
  const attempts = [];
  const node = await serve(async (request, response) => {
    attempts.push({
      method: request.method,
      path: request.url,
      key: request.headers["idempotency-key"],
      body: await readBody(request),
    });
    if (attempts.length === 1) {
      response.destroy(); // The node has received the mutation; the reply is ambiguous.
      return;
    }
    json(response, 200, {
      committed: true,
      result: { output: { acquired: true, fencing_token: 91 } },
    });
  });
  t.after(node.close);
  const sdk = new FiduciaClient(node.url, { maxRetries: 1 });
  const accepted = await sdk.tryLock("batch/91", {
    holder: "worker-retry",
    requestId: "durable-attempt-91",
    idempotencyKey: "durable-ledger-key-91",
  });
  assert.equal(accepted.result.output.fencing_token, 91);
  assert.equal(attempts.length, 2);
  assert.deepEqual(attempts[1], attempts[0], "wire retry must preserve the exact logical attempt");
  assert.equal(attempts[0].method, "POST");
  assert.equal(attempts[0].key, "durable-ledger-key-91");
});

test("SDK -> node: a lost POST response without a durable key never replays the write", async (t) => {
  let observedWrites = 0;
  const node = await serve(async (request, response) => {
    observedWrites++;
    await readBody(request);
    response.destroy(); // External side-effect could already be committed.
  });
  t.after(node.close);
  const sdk = new FiduciaClient(node.url, { maxRetries: 3 });
  await assert.rejects(() => sdk.tryLock("critical", {
    holder: "worker-unkeyed",
    requestId: "unkeyed-attempt-91",
  }));
  assert.equal(observedWrites, 1, "connection failure cannot authorize duplicate mutations");
});

test("SDK -> node: a fragmented SSE stream decodes two event frames across TCP chunks", async (t) => {
  const requested = [];
  const node = await serve(async (request, response) => {
    requested.push({ method: request.method, url: request.url, accept: request.headers.accept });
    response.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-store" });
    response.write(": heartbeat\n\n");
    response.write("event: update\nid: seq-");
    response.write("01\ndata: {\"key\":\"catalog/a\",\"revision\":1}\n\n");
    response.write("event: update\nid: seq-02\ndata: {\"key\":");
    response.end("\"catalog/b\",\"revision\":2}\n\n");
  });
  t.after(node.close);
  const sdk = new FiduciaClient(node.url);
  const events = [];
  for await (const event of sdk.kvWatchPrefix("catalog/")) events.push(event);
  assert.deepEqual(requested, [{
    method: "GET",
    url: "/v1/kv?prefix=catalog%2F&watch=true",
    accept: "text/event-stream",
  }]);
  assert.deepEqual(events, [
    { event: "update", id: "seq-01", data: { key: "catalog/a", revision: 1 } },
    { event: "update", id: "seq-02", data: { key: "catalog/b", revision: 2 } },
  ]);
});

test("SDK -> node: a retryable GET may move past 503 but preserves request URL", async (t) => {
  const paths = [];
  const node = await serve(async (request, response) => {
    paths.push([request.method, request.url]);
    if (paths.length === 1) json(response, 503, { error: "leader_election" });
    else json(response, 200, { value: "after-recovery" });
  });
  t.after(node.close);
  const sdk = new FiduciaClient(node.url, { maxRetries: 1 });
  const response = await sdk.kvGet("space/with a slash");
  assert.equal(response.value, "after-recovery");
  assert.deepEqual(paths, [
    ["GET", "/v1/kv?key=space%2Fwith%20a%20slash"],
    ["GET", "/v1/kv?key=space%2Fwith%20a%20slash"],
  ]);
});
