# Gleam client source

- `fiducia.gleam` — the whole Gleam client. Wraps the fiducia.cloud coordination API
  over the shared `PROTOCOL.md` contract. Transport is `gleam_httpc`, JSON via
  `gleam_json`, plus `gleam_stdlib`. Build a client with `fiducia.new`, then pass it
  first to every operation; responses come back as `Dynamic` for the caller to decode.
- `fiducia_ffi.erl` — tiny dependency-free Erlang FFI backing the blocking acquire poll
  loops: a monotonic clock, a sleep, and a random holder-id generator.
