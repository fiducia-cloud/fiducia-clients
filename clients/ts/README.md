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
- `deno.json` — Deno-native exports and the import-map bridge to
  `@fiducia/interfaces/typescript`.

## Runtime support

The production source uses only standards-based TypeScript plus the Web Fetch
API. Zed therefore publishes the self-contained `clients/ts` directory through
four independent targets:

- Node.js 18+
- Deno
- Bun
- edge isolates such as Cloudflare Workers, Deno Deploy, and Vercel Edge

These are separate Zed runtime targets over one source root, not copied SDKs.
Keeping one implementation prevents operation and protocol drift. The required
client-matrix check rejects Node built-ins, CommonJS `require`, and `process`
globals in the production source before the edge target can be published.

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
