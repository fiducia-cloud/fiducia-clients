# Erlang client source

- `fiducia.erl` — the whole Erlang client in one module. Wraps the fiducia.cloud
  coordination API over the shared `PROTOCOL.md` contract using only stdlib `httpc`
  (inets) and `json` (OTP 27+). Convention: `{ok, Decoded}` on HTTP status < 300 and
  `{error, {Status, Body}}` on >= 300, with payloads parsed to maps with binary keys.
  Build a client with `fiducia:new/1`, then pass it first to every operation.
- `fiducia_client.app.src` — the OTP application resource file, which also carries the
  Hex package metadata that `rebar3_hex` reads at publish time.
