# Fiducia (TypeScript)

Zero-runtime-dependency TypeScript client for fiducia.cloud built on the global
`fetch`. Implements the shared `PROTOCOL.md` contract.

- `fiducia.ts` — the thin client, generated from `operations.json` by
  `generate.py` (do not edit by hand).
- `locking.ts` — hand-written live-mutex-style lock/semaphore ergonomics on top
  of the generated client.
- `fiducia.test.ts` — offline unit tests (`node:test`).
- `package.json` / `publish.sh` — npm packaging manifest and publish entrypoint
  (see `clients/PUBLISHING.md`).
