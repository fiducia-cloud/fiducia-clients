# Fiducia client (OCaml) — library

Library source for the OCaml Fiducia client. `fiducia.ml` defines module `Fiducia`: a synchronous HTTP client (ezcurl/libcurl transport, yojson, uri) implementing the shared `PROTOCOL.md` contract, raising `Fiducia_error` on HTTP status >= 300. `dune` is the build stanza for this library; project metadata lives one level up in `clients/ocaml`.
