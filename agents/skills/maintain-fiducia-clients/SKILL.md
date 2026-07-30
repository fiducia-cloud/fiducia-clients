---
name: maintain-fiducia-clients
description: Maintain Fiducia's polyglot client family and generated endpoint surface. Use when changing operations.json, PROTOCOL.md, generator templates, generated clients, retries, cancellation, authentication, sync adapters, packaging, release metadata, or cross-language contract tests.
---

# Maintain Fiducia clients

## Establish the source of truth

Read `operations.json` for the machine-readable operation set and `PROTOCOL.md`
for reviewed semantics. Read `templates/` before changing production-tier
generated regions. Keep hand-written transport hardening outside generated
regions intact.

When the wire contract changes, update the canonical `fiducia-interfaces`
schema first and advance its reviewed full commit everywhere together. Never
replace an immutable interface pin with a branch, tag, or short hash.

## Preserve parity

1. Add or change the operation manifest and regression fixtures.
2. Update generator logic and the applicable template.
3. Regenerate all affected clients.
4. Review generated diffs for idiomatic names, wire casing, error behavior, and
   package boundaries.
5. Add focused tests for ambiguous transport outcomes, retries, cancellation,
   or fencing behavior.
6. Update package documentation and publication metadata only when the public
   surface changes.

Keep try helpers non-waiting and must/short helpers waiting. Generate a new
request ID per logical acquisition, reuse it across that attempt's retries and
cancel, then discard it. Surface `cancellation_capacity` and failed raced-grant
release; never report a safe timeout while acquisition may still commit.

## Guard security and releases

- Never invent a customer idempotency key or authentication credential.
- Preserve no-redirect transports and bounded error handling.
- Keep secret KV values out of list responses, logs, fixtures, and debug output.
- Treat internal authentication as service-to-node only.
- Keep package versions, tags, lockfiles, and dry-run artifacts aligned.
- Never invoke `--release`, create tags, or upload packages without explicit
  release authorization.

## Validate

Run generator drift checks before package suites:

```bash
python3 -m unittest generate_test
python3 generate.py --check
(cd clients/ts && npm ci --ignore-scripts && npm test && npm run typecheck && npm audit --audit-level=high)
(cd clients/go && go test ./...)
(cd clients/rust && cargo fmt --all -- --check && cargo clippy --locked --all-targets --all-features -- -D warnings && cargo test --all-targets --all-features --locked)
(cd clients/python && PYTHONDONTWRITEBYTECODE=1 python3 -m unittest fiducia_test.py)
(cd clients/dart && dart pub get && dart format --output=none --set-exit-if-changed . && dart analyze && dart run fiducia_sync_test.dart && dart run fiducia_secrets_test.dart)
```

Run the affected `clients/<language>/publish.sh --dry-run` and the repository's
packaging checks for a package or release-surface change.
