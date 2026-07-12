# Zig client sources

`fiducia.zig` — the entire Zig Fiducia client, a dependency-free HTTP client
using only the Zig standard library (`std.http.Client` transport, `std.json`
encode/decode). Exposes `fiducia.Client` with one method per `PROTOCOL.md`
operation. Written and verified against Zig 0.16.0 (the `std.http`/`std.Io` APIs
are version-sensitive). See the client's `../README.md` for install and usage.
