# Fiducia client (OCaml)

Synchronous OCaml HTTP client for [fiducia.cloud](https://fiducia.cloud): ezcurl (libcurl) for transport, yojson for JSON, uri for URL-encoding. Implements the shared `PROTOCOL.md` contract.

- `lib/fiducia.ml` — the client source (module `Fiducia`); operations return `Yojson.Safe.t`.
- `dune-project` / `fiducia-client.opam` — dune/opam project metadata; `publish.sh` is the build/validate/release entrypoint.
