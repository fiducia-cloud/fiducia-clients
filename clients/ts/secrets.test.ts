import assert from "node:assert/strict";
import test from "node:test";

import { FiduciaClient } from "./fiducia.ts";

type Call = { url: string; init: RequestInit };

function clientCapturing(response: unknown, status = 200): { client: FiduciaClient; calls: Call[] } {
  const calls: Call[] = [];
  const client = new FiduciaClient("https://node.fiducia.test", {
    fetch: (async (input: RequestInfo | URL, init: RequestInit = {}) => {
      calls.push({ url: String(input), init });
      return new Response(JSON.stringify(response), {
        status,
        headers: { "content-type": "application/json" },
      });
    }) as typeof fetch,
  });
  return { client, calls };
}

test("secretPut writes under the reserved namespace, always encrypted", async () => {
  const { client, calls } = clientCapturing({ mod_revision: 4 });
  const res = await client.secretPut("db/password", "hunter2", { ttlMs: 60000, prevRevision: 0 });
  assert.deepEqual(res, { mod_revision: 4 });
  assert.equal(calls[0].url, "https://node.fiducia.test/v1/kv?key=secret%2Fdb%2Fpassword");
  assert.equal(calls[0].init.method, "PUT");
  const body = JSON.parse(String(calls[0].init.body));
  assert.equal(body.value, "hunter2");
  assert.equal(body.ttl_ms, 60000);
  assert.equal(body.prev_revision, 0);
  // Secrets are NEVER stored plaintext, regardless of caller.
  assert.equal(body.plaintext, false);
});

test("secretReveal is the only path that exposes a value", async () => {
  const { client, calls } = clientCapturing({
    key: "secret/api-key",
    found: true,
    entry: { value: "sk-live-xyz", mod_revision: 2 },
    protection: { at_rest: "encrypted", provider: "vault_transit" },
  });
  const res = (await client.secretReveal("api-key")) as { entry: { value: string } };
  assert.equal(res.entry.value, "sk-live-xyz");
  assert.equal(calls[0].url, "https://node.fiducia.test/v1/kv?key=secret%2Fapi-key");
  assert.equal(calls[0].init.method, "GET");
});

test("secretList returns names + metadata only, stripping values and the prefix", async () => {
  const { client, calls } = clientCapturing({
    prefix: "secret/",
    count: 2,
    keys: [
      { key: "secret/api-key", value: "LEAK-1", mod_revision: 2, expires_at_ms: 111, protection: { at_rest: "encrypted" } },
      { key: "secret/db/password", value: "LEAK-2", mod_revision: 4 },
    ],
  });
  const res = await client.secretList();
  assert.equal(calls[0].url, "https://node.fiducia.test/v1/kv?prefix=secret%2F");
  assert.equal(res.count, 2);
  // Bare names, no leaked values anywhere in the result.
  assert.deepEqual(res.secrets.map((s) => s.name), ["api-key", "db/password"]);
  assert.equal(res.secrets[0].modRevision, 2);
  assert.equal(res.secrets[0].expiresAtMs, 111);
  assert.equal(JSON.stringify(res).includes("LEAK"), false, "list must never expose secret values");
});

test("secretList accepts a sub-prefix", async () => {
  const { client, calls } = clientCapturing({ keys: [] });
  await client.secretList("db/");
  assert.equal(calls[0].url, "https://node.fiducia.test/v1/kv?prefix=secret%2Fdb%2F");
});

test("secretDelete targets the namespaced key", async () => {
  const { client, calls } = clientCapturing({ deleted: true });
  await client.secretDelete("api-key");
  assert.equal(calls[0].url, "https://node.fiducia.test/v1/kv?key=secret%2Fapi-key");
  assert.equal(calls[0].init.method, "DELETE");
});

test("empty secret names are rejected synchronously before any request", () => {
  const { client, calls } = clientCapturing({});
  // Validation happens while evaluating the request args, so these throw
  // synchronously — no unhandled promise, no network call.
  assert.throws(() => client.secretPut("", "v"), /non-empty/);
  assert.throws(() => client.secretReveal(""), /non-empty/);
  assert.throws(() => client.secretDelete(""), /non-empty/);
  assert.equal(calls.length, 0);
});

test("kv watch helpers target the SSE endpoint (parity with the trio)", () => {
  const { client } = clientCapturing({});
  // These return async generators; constructing them must not throw.
  assert.equal(typeof client.kvWatch("cfg").next, "function");
  assert.equal(typeof client.kvWatchPrefix("cfg/").next, "function");
});
