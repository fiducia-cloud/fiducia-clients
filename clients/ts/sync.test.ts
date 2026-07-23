import assert from "node:assert/strict";
import test from "node:test";

import type { SyncQueuedWrite } from "@fiducia/interfaces/typescript";
import { FiduciaClient } from "./fiducia.ts";

const write: SyncQueuedWrite = {
  id: "operation-7",
  table: "infra_operations",
  op: "upsert",
  payload: { state: "queued" },
  base_version: 3,
  key: "write-operation-7-v4",
};

test("syncSender sends the canonical interface envelope and durable key", async () => {
  const calls: Array<{ url: string; init: RequestInit }> = [];
  const client = new FiduciaClient("https://admin.fiducia.test", {
    fetch: (async (input: RequestInfo | URL, init: RequestInit = {}) => {
      calls.push({ url: String(input), init });
      return new Response(JSON.stringify({ id: write.id, committed_version: 4 }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }) as typeof fetch,
  });

  const send = client.syncSender({ pathPrefix: "/api/admin/sync" });
  assert.deepEqual(await send(write), { id: write.id, committed_version: 4 });
  assert.equal(calls[0].url, "https://admin.fiducia.test/api/admin/sync/infra_operations");
  assert.equal(calls[0].init.method, "POST");
  assert.equal(new Headers(calls[0].init.headers).get("idempotency-key"), write.key);
  assert.deepEqual(JSON.parse(String(calls[0].init.body)), write);
});

test("syncPull returns the canonical pull page consumed by fiducia-sync", async () => {
  const client = new FiduciaClient("https://admin.fiducia.test", {
    fetch: (async (input: RequestInfo | URL) => {
      assert.equal(
        String(input),
        "https://admin.fiducia.test/api/admin/sync/infra_operations?cursor=40&limit=2",
      );
      return new Response(JSON.stringify({
        changes: [{
          sequence: 41,
          table: "infra_operations",
          op: "upsert",
          id: "operation-7",
          version: 4,
          row: { state: "running" },
        }],
        next_cursor: 41,
        has_more: false,
      }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }) as typeof fetch,
  });

  assert.deepEqual(
    await client.syncPull("infra_operations", 40, {
      pathPrefix: "/api/admin/sync",
      limit: 2,
    }),
    {
      changes: [{
        table: "infra_operations",
        op: "upsert",
        id: "operation-7",
        version: 4,
        row: { state: "running" },
        at_ms: 0,
        sync_sequence: 41,
      }],
      next_cursor: 41,
      has_more: false,
    },
  );
});

test("sync acknowledgements fail closed on the wrong row", async () => {
  const client = new FiduciaClient("https://admin.fiducia.test", {
    fetch: (async () => new Response(JSON.stringify({
      id: "another-row",
      committed_version: 4,
    }), {
      status: 200,
      headers: { "content-type": "application/json" },
    })) as typeof fetch,
  });

  await assert.rejects(
    client.syncWrite(write, { pathPrefix: "/api/admin/sync" }),
    /acknowledgement id does not match/,
  );
});

test("legacy queue entries are upgraded to the canonical keyed wire body", async () => {
  let capturedBody: unknown;
  let capturedKey: string | null = null;
  const client = new FiduciaClient("https://admin.fiducia.test", {
    fetch: (async (_input: RequestInfo | URL, init: RequestInit = {}) => {
      capturedBody = JSON.parse(String(init.body));
      capturedKey = new Headers(init.headers).get("idempotency-key");
      return new Response(JSON.stringify({ id: "operation-7", committed_version: 4 }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }) as typeof fetch,
  });

  await client.syncWrite({
    id: "operation-7",
    table: "infra_operations",
    op: "upsert",
    payload: { state: "queued" },
    base_version: 3,
  });
  assert.equal(capturedKey, "infra_operations:operation-7:upsert:3");
  assert.deepEqual(capturedBody, {
    id: "operation-7",
    table: "infra_operations",
    op: "upsert",
    payload: { state: "queued" },
    base_version: 3,
    key: "infra_operations:operation-7:upsert:3",
  });
});
