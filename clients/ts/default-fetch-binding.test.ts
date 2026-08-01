import assert from "node:assert/strict";
import test from "node:test";

import { FiduciaClient } from "./fiducia.ts";

test("default fetch is bound to the global receiver", async () => {
  const originalFetch = globalThis.fetch;
  let receiver: unknown;
  globalThis.fetch = (async function (this: unknown) {
    receiver = this;
    return new Response(JSON.stringify({ key: "orders/42" }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }) as typeof fetch;

  try {
    const client = new FiduciaClient("https://fiducia.test");
    await client.lockGet("orders/42");
    assert.equal(receiver, globalThis);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("an injected fetch implementation is not rebound", async () => {
  const customReceiver = { name: "custom" };
  let receiver: unknown;
  const customFetch = (async function (this: unknown) {
    receiver = this;
    return new Response(JSON.stringify({ key: "orders/42" }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }) as typeof fetch;

  const client = new FiduciaClient("https://fiducia.test", {
    fetch: customFetch.bind(customReceiver),
  });
  await client.lockGet("orders/42");
  assert.equal(receiver, customReceiver);
});
