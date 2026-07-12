# CI workflows

GitHub Actions pipelines for the multi-language client monorepo.

- `ci.yml` — builds/tests each language client on push and PR. Every client job is best-effort (`continue-on-error`), because several carry local path deps on the sibling `fiducia-interfaces` repo that aren't present in single-repo CI, so one failure must not gate the others.
- `cli-flags.yml` — audits `.cli-flags.toml` against the pinned `flags-2-env` tool whenever the CLI flag config (or its submodule/wrapper) changes.
- `client-packaging.yml` — verifies each client's publishable artifact rather than its repo-relative source; see `client-packaging-NOTES.md` for the rationale.
