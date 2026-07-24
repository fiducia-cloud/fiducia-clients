# Fiducia (TypeScript)

Zero-runtime-dependency TypeScript client for fiducia.cloud built on the global
`fetch`. Implements the shared `PROTOCOL.md` contract.

- `fiducia.ts` — the production client, generated from
  `templates/typescript.ts.tmpl` plus `operations.json` (do not edit by hand).
- `locking.ts` — hand-written live-mutex-style lock/semaphore ergonomics on top
  of the generated client.
- `sync-compatibility.ts` — compile-time proof that `syncSender()` and
  `syncPull()` satisfy `@fiducia/sync`'s transport callback types.
- `fiducia.test.ts` — offline unit tests (`node:test`).
- `package.json` / `publish.sh` — npm packaging manifest and publish entrypoint
  (see `clients/PUBLISHING.md`).

There is no dedicated bearer-token constructor option yet. Authenticated callers
must inject a `fetch` wrapper that adds the required header.

The sync methods use `SyncQueuedWrite`, `SyncWriteAcknowledgement`, and
`SyncPullPage` from `@fiducia/interfaces/typescript`:

```ts
const send = client.syncSender({ pathPrefix: "/api/admin/sync" });
const pullFetch = (cursor: number, limit: number) =>
  client.syncPull("infra_operations", cursor, {
    pathPrefix: "/api/admin/sync",
    limit,
  });
```

Pass `send` to policy-driven `write()`/`flushQueue()` and `pullFetch` to
`startSync()`. The sender accepts `@fiducia/sync`'s replica-only
`write_policy`, strips it before HTTP IO, and sends only the canonical
`SyncQueuedWrite` envelope.
