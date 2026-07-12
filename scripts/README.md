# scripts

Shared, language-agnostic release and tooling plumbing. Language-specific
publishing policy lives in each client's own `publish.sh`, not here.

- `publish-client.sh` — compatibility dispatcher: `publish-client.sh <language> ...` forwards to `clients/<language>/publish.sh`. Contains no per-language policy.
- `publish-common.sh` — generic release plumbing sourced by every `publish.sh`: argument/mode parsing, credential checks, safe git-tag mechanics, and the shared version-drift guard.
- `with-flags2env.sh` — resolves CLI flags to `FIDUCIA_*` env vars via the `flags-2-env` tool, then execs the given command.
