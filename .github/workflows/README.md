# CI workflows

GitHub Actions pipelines for the multi-language client monorepo.

- `ci.yml` — hard-gates the production-tier TypeScript, Go, Rust, Python, and
  Rust-Wasm clients on push and PR. Jobs that use sibling path dependencies
  check out the reviewed full `fiducia-interfaces` commit; they do not follow a
  moving branch. npm and both Rust lockfiles are mandatory audit gates, and all
  Cargo resolution uses `--locked`.
- `browser-e2e.yml` — emits the TypeScript client as a browser ES module with
  the locked compiler and executes its contract in the Chrome installation
  shipped on the selected GitHub runner image. The job resolves the executable
  fail-closed, records its exact version, and drives the page through Chrome's
  loopback-bound DevTools Protocol until the explicit pass/fail state is
  terminal. The live loopback server exercises real browser fetch redirect
  behavior, AbortController timeouts, Web Crypto holder generation, marked
  not-leader retries with a stable idempotency key, and SSE stream decoding.
- `cli-flags.yml` — audits `.cli-flags.toml` against the pinned `flags-2-env` tool whenever the CLI flag config (or its submodule/wrapper) changes.
- `client-packaging.yml` — hard-gates each supported client's publishable
  artifact rather than its repo-relative source; a failure in any language
  blocks publication. See `client-packaging-NOTES.md` for the rationale.

## Browser transport invariant

When the caller does not inject a transport, the TypeScript client binds
`globalThis.fetch` to the global receiver before storing it. Browser `fetch` is a
Web IDL method and an unbound reference can fail with `Illegal invocation` even
when equivalent Node tests pass. The Node receiver regression and the Chrome
contract must both stay green whenever the generated TypeScript template changes.

## Security baseline

Every executable workflow uses explicit least-privilege permissions, immutable
third-party action or container references, non-persisted checkout credentials,
concurrency control, and a job timeout. Browser CI performs no runtime browser
installer download; it records and validates the runner browser identity, binds
DevTools to loopback, and runs against a loopback-only server with a restrictive
CSP, an ephemeral browser profile, and bounded request bodies. Workflows validate
their own YAML with the digest-pinned actionlint container. Environment mutation
is forbidden unless this README documents a repository-specific platform exception.
