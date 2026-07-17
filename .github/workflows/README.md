# CI workflows

GitHub Actions pipelines for the multi-language client monorepo.

- `ci.yml` — hard-gates the production-tier TypeScript, Go, Rust, Python, and
  Rust-Wasm clients on push and PR. Jobs that use sibling path dependencies
  check out the reviewed full `fiducia-interfaces` commit; they do not follow a
  moving branch. npm and both Rust lockfiles are mandatory audit gates, and all
  Cargo resolution uses `--locked`.
- `cli-flags.yml` — audits `.cli-flags.toml` against the pinned `flags-2-env` tool whenever the CLI flag config (or its submodule/wrapper) changes.
- `client-packaging.yml` — hard-gates each supported client's publishable
  artifact rather than its repo-relative source; a failure in any language
  blocks publication. See `client-packaging-NOTES.md` for the rationale.

## Security baseline

Every executable workflow uses explicit least-privilege permissions, immutable
third-party action or container references, non-persisted checkout credentials,
concurrency control, and a job timeout. The main CI workflow validates this
directory with the digest-pinned actionlint container. Environment mutation is
forbidden unless this README documents a repository-specific platform exception.
