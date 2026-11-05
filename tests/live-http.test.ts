// Real client/server transport tests for the generated TypeScript SDK.
// These exercise Node's HTTP parser, sockets and global fetch, not a fake fetch.
// The upstream is deliberately small and deterministic; no cloud credentials.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { test } from "node:test";
import { FiduciaClient, FiduciaError } from "../clients/ts/fiducia.ts";

async function listen(handler: (req: any, res: any) => Promise<void> | void) {
  const server = createServer((req, res) => {
    Promise.resolve(handler(req, res)).catch((error) => {
      if (!res.headersSent) res.writeHead(500, { "content-type": "application/json" });
      res.end(JSON.stringify({ fixture_error: error.message }));
    });
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  return {
    url: "http://127.0.0.1:" + (server.address() as { port: number }).port,
    close: () => new Promise<void>((resolve, reject) =>
      server.close((error) => error ? reject(error) : resolve())),
  };
}

async function bodyOf(request: AsyncIterable<Buffer>): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of request) chunks.push(Buffer.from(chunk));
  return Buffer.concat(chunks).toString("utf8");
}

function answer(res: any, status: number, body: unknown, extra: Record<string, string> = {}) {
  res.writeHead(status, { "content-type": "application/json", ...extra });
  res.end(JSON.stringify(body));
}

test("real HTTP: an ambiguous committed KV write retries only with a stable idempotency key", async (t) => {
  const wire: Array<{ method: string; path: string; idempotencyKey: string | undefined; raw: string }> = [];
  const committed = new Map<string, string>();
  const ledger = new Map<string, unknown>();
  let stateChanges = 0;
  const server = await listen(async (req, res) => {
    const raw = await bodyOf(req);
    const url = new URL(req.url || "/", "http://loopback");
    const idempotencyKey = req.headers["idempotency-key"] as string | undefined;
    wire.push({ method: req.method, path: url.pathname + url.search, idempotencyKey, raw });
    if (url.pathname !== "/v1/kv") return answer(res, 404, { error: "not_found" });
    const key = url.searchParams.get("key");
    if (req.method === "GET") {
      return key !== null && committed.has(key)
        ? answer(res, 200, { value: committed.get(key) })
        : answer(res, 404, { error: "not_found" });
    }
    if (req.method !== "PUT" || !key) return answer(res, 405, { error: "invalid_method" });
    if (idempotencyKey && ledger.has(idempotencyKey)) {
      return answer(res, 200, ledger.get(idempotencyKey));
    }
    const payload = JSON.parse(raw);
    committed.set(key, payload.value);
    stateChanges += 1;
    const reply = { committed: true, result: { output: { value: payload.value } } };
    if (idempotencyKey) ledger.set(idempotencyKey, reply);
    // Simulate a write committed by the server, followed by response loss.
    // A blind replay could apply the mutation twice.
    res.socket?.destroy();
  });
  t.after(server.close);

  const client = new FiduciaClient(server.url, { maxRetries: 2, retryDelayMs: 1 });
  const result = await client.kvPut("tenant/orders/42", "new-value", {
    idempotencyKey: "req-e2e-kv-42",
    ttlMs: 5000,
  });
  assert.equal(result.committed, true);
  assert.equal(stateChanges, 1, "the retry must not apply a second mutation");
  assert.equal(wire.length, 2, "client must retry the ambiguous response once");
  assert.deepEqual(wire.map((hit) => hit.method), ["PUT", "PUT"]);
  assert.deepEqual(wire.map((hit) => hit.path), [
    "/v1/kv?key=tenant%2Forders%2F42",
    "/v1/kv?key=tenant%2Forders%2F42",
  ]);
  assert.deepEqual(wire.map((hit) => hit.idempotencyKey), [
    "req-e2e-kv-42", "req-e2e-kv-42",
  ]);
  assert.equal(wire[0].raw, wire[1].raw, "retry body must remain byte-identical");
  assert.deepEqual(JSON.parse(wire[0].raw), {
    value: "new-value",
    ttl_ms: 5000,
  });
  assert.deepEqual(await client.kvGet("tenant/orders/42"), { value: "new-value" });
});

test("real HTTP: a lock mutation without an idempotency key is never retried after a 503", async (t) => {
  let accepted = 0;
  const server = await listen(async (req, res) => {
    if (req.method !== "POST" || req.url !== "/v1/locks/acquire") {
      return answer(res, 404, { error: "not_found" });
    }
    const body = JSON.parse(await bodyOf(req));
    assert.equal(body.key, "orders/42");
    accepted += 1;
    answer(res, 503, { error: "response_lost_after_commit" });
  });
  t.after(server.close);
  const client = new FiduciaClient(server.url, { maxRetries: 3, retryDelayMs: 1 });
  await assert.rejects(
    () => client.tryLock("orders/42", { holder: "worker-a", ttlMs: 5000 }),
    (error: unknown) => {
      assert.ok(error instanceof FiduciaError);
      assert.equal(error.status, 503);
      return true;
    },
  );
  assert.equal(accepted, 1, "503 after a possible commit must not duplicate a lock");
});

test("real HTTP: an attacker redirect cannot steal a mutation or trigger a second request", async (t) => {
  let attackerRequests = 0;
  let gatewayRequests = 0;
  const attacker = await listen(async (_req, res) => {
    attackerRequests += 1;
    answer(res, 200, { stolen: true });
  });
  t.after(attacker.close);
  const gateway = await listen(async (_req, res) => {
    gatewayRequests += 1;
    res.writeHead(307, { location: attacker.url + "/capture" });
    res.end();
  });
  t.after(gateway.close);

  const client = new FiduciaClient(gateway.url, { maxRetries: 3 });
  await assert.rejects(
    () => client.tryLock("orders/42", { holder: "worker-a", ttlMs: 5000 }),
    (error: unknown) => {
      assert.ok(error instanceof FiduciaError);
      assert.equal(error.status, 307);
      assert.equal(error.body?.error, "redirect_not_followed");
      return true;
    },
  );
  assert.equal(gatewayRequests, 1);
  assert.equal(attackerRequests, 0);
});
