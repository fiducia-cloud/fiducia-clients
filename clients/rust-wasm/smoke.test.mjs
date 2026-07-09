// Runtime smoke test for the generated wasm client — exercises the actual
// compiled wasm against a stubbed global `fetch` (behavior that the compile and
// .d.ts checks cannot catch: wire format, integer bodies, timeout, errors).
//
//   wasm-pack build clients/rust-wasm --target nodejs --dev
//   node --test clients/rust-wasm/smoke.test.mjs
//
// Requires Node 18+ (global fetch/Request/Response) and 17.3+ for
// AbortSignal.timeout — both satisfied by the CI node version.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const wasm = require("./pkg/fiducia_client_wasm.js");

// Install a fetch stub that records requests and honors the abort signal.
function stubFetch(handler) {
  const calls = [];
  globalThis.fetch = (req) =>
    new Promise((resolve, reject) => {
      if (req.signal) {
        req.signal.addEventListener("abort", () =>
          reject(req.signal.reason || new Error("aborted")),
        );
      }
      (async () => {
        const hasBody = req.method !== "GET" && req.method !== "DELETE";
        calls.push({
          method: req.method,
          url: req.url,
          contentType: req.headers.get("content-type"),
          body: hasBody ? await req.text() : null,
        });
        resolve(await handler(req));
      })();
    });
  return calls;
}

const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });

test("metadata object query expands to dotted metadata.KEY=VALUE pairs", async () => {
  const calls = stubFetch(() => json({ instances: [] }));
  const c = new wasm.FiduciaClient("https://x");
  await c.serviceInstances("api", { region: "us-east-1", version: "blue" });
  assert.equal(
    calls[0].url,
    "https://x/v1/services/api?metadata.region=us-east-1&metadata.version=blue",
  );
});

test("serviceInstances without metadata sends no query", async () => {
  const calls = stubFetch(() => json({ instances: [] }));
  const c = new wasm.FiduciaClient("https://x");
  await c.serviceInstances("api");
  assert.equal(calls[0].url, "https://x/v1/services/api");
});

test("integer body fields stay clean integers (no 30000.0 / bigint)", async () => {
  const calls = stubFetch(() => json({ committed: true }));
  const c = new wasm.FiduciaClient("https://x");
  await c.lockAcquire("orders/checkout", "worker-a", 30000, false);
  assert.equal(calls[0].method, "POST");
  assert.equal(calls[0].contentType, "application/json");
  assert.match(calls[0].body, /"ttl_ms":30000(,|})/); // integer, not 30000.0
  assert.equal(JSON.parse(calls[0].body).ttl_ms, 30000);
});

test("path/query values are URL-encoded", async () => {
  const calls = stubFetch(() => json({}));
  const c = new wasm.FiduciaClient("https://x");
  await c.kvGet("flags/new-ui");
  assert.equal(calls[0].url, "https://x/v1/kv?key=flags%2Fnew-ui");
});

test("2xx resolves to parsed body; non-2xx rejects with {status, body}", async () => {
  let status = 200;
  stubFetch(() =>
    status === 200 ? json({ committed: true }) : json({ error: "nope" }, 404),
  );
  const c = new wasm.FiduciaClient("https://x");
  const ok = await c.kvGet("k");
  assert.equal(ok.committed, true);

  status = 404;
  await assert.rejects(
    () => c.kvGet("k"),
    (e) => {
      assert.equal(e.status, 404);
      assert.equal(e.body.error, "nope");
      return true;
    },
  );
});

test("non-JSON error body surfaces as raw text", async () => {
  stubFetch(
    () =>
      new Response("Bad Gateway", {
        status: 502,
        headers: { "content-type": "text/plain" },
      }),
  );
  const c = new wasm.FiduciaClient("https://x");
  await assert.rejects(
    () => c.health(),
    (e) => {
      assert.equal(e.status, 502);
      assert.equal(e.body, "Bad Gateway");
      return true;
    },
  );
});

test("default headers (auth, idempotency-key) are attached; replace/remove work", async () => {
  let seen;
  globalThis.fetch = async (req) => {
    seen = {
      auth: req.headers.get("authorization"),
      idem: req.headers.get("idempotency-key"),
    };
    return json({});
  };
  const c = new wasm.FiduciaClient("https://x");
  c.setHeader("Authorization", "Bearer tok-123");
  c.setHeader("Idempotency-Key", "req-1");
  await c.health();
  assert.deepEqual(seen, { auth: "Bearer tok-123", idem: "req-1" });

  c.setHeader("authorization", "Bearer tok-2"); // case-insensitive replace
  c.removeHeader("idempotency-key");
  await c.health();
  assert.deepEqual(seen, { auth: "Bearer tok-2", idem: null });
});

test("timeout aborts a slow request; a fast one under the timeout resolves", async () => {
  globalThis.fetch = (req) =>
    new Promise((resolve, reject) => {
      const t = setTimeout(() => resolve(json({})), 500);
      if (req.signal) {
        req.signal.addEventListener("abort", () => {
          clearTimeout(t);
          reject(req.signal.reason || new Error("aborted"));
        });
      }
    });

  const slow = new wasm.FiduciaClient("https://x", 40);
  await assert.rejects(
    () => slow.health(),
    (e) => {
      assert.equal(e.status, 0);
      return true;
    },
  );

  // Same slow fetch, but a generous timeout -> resolves.
  globalThis.fetch = () => Promise.resolve(json({ ok: true }));
  const fast = new wasm.FiduciaClient("https://x", 1000);
  const r = await fast.health();
  assert.equal(r.ok, true);
});
