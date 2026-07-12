# Fiducia (Rust → WebAssembly)

The Rust Fiducia client compiled to WebAssembly for JavaScript hosts, generated
from `operations.json` by `generate.py`. Transport is the global `fetch`
(browsers, Web Workers, Node 18+/Deno); every operation is an `async` method
exported to JS as camelCase. Implements the shared `PROTOCOL.md` contract.

- `src/lib.rs` — the generated `wasm-bindgen` client (do not edit by hand).
- `Cargo.toml` — crate manifest (`cdylib`, web-sys fetch bindings).
- `smoke.test.mjs` — runtime smoke test against a stubbed `fetch`.
- `publish.sh` — `wasm-pack` build + npm publish (see `clients/PUBLISHING.md`).
