---
name: integrate-fiducia-client
description: Integrate an official Fiducia coordination client into an application. Use when choosing among the supported language SDKs; adding locks, semaphores, idempotency, scheduling, configuration, elections, or service discovery; or deciding how authentication, retries, cancellation, and fencing tokens must work.
---

# Integrate a Fiducia client

## Select the contract and package

Read `README.md`, `PROTOCOL.md`, and the selected package under `clients/`.
Use `operations.json` to confirm endpoint coverage. Prefer the hard-gated
TypeScript, Go, Rust, or Python client when the host language allows it; use
another generated client only after checking its package and CI status.

Do not infer hosted authentication support from an example. Confirm the
selected package's authentication readiness in `README.md`. Internal
`x-fiducia-internal-auth` is not customer authentication.

## Choose the primitive

- Use a lock or multi-key union lock for exclusive ownership.
- Use a semaphore for bounded concurrency.
- Use idempotency claim/complete for one-time business effects.
- Use reader-writer locks for concurrent readers and exclusive writers.
- Use rate limiting for tenant/action admission control.
- Use schedules for durable cron/webhook intent.
- Use config KV for versioned values and TTLs.
- Use leader election plus fencing tokens for failover-safe singleton work.
- Use service registration/discovery for live instance routing.

Keep holder identity separate from the per-attempt request ID. Pass fencing
tokens to downstream systems that can reject stale owners.

## Integrate safely

- Point hosted clients at the load-balancer/edge endpoint. A direct node does
  not provide the customer HTTP idempotency-key replay ledger.
- Bound blocking waits, retries, and cancellation using the selected runtime's
  controls.
- Retry non-idempotent requests only with one stable caller-supplied
  `Idempotency-Key` and only where the deployment honors it.
- Preserve redirect refusal so mutations and credentials are never replayed to
  an untrusted `Location`.
- Stop leader-only work immediately after renewal fails or reports
  `not_leader`.
- Never log credentials, secret values, fencing tokens, or unbounded server
  bodies.

## Validate

Run the native tests for the selected package. For hard-gated clients:

```bash
(cd clients/ts && npm ci --ignore-scripts && npm test && npm run typecheck)
(cd clients/go && go test ./...)
(cd clients/rust && cargo test --all-targets --all-features --locked)
(cd clients/python && PYTHONDONTWRITEBYTECODE=1 python -m unittest fiducia_test.py)
```

Use the sibling `fiducia-interfaces` checkout and reviewed revision when a
package declares that path relationship. Do not publish as part of integration
work.
