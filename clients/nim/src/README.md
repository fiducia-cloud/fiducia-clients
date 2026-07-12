# Fiducia client (Nim) — source

Module source for the Nim Fiducia client. `fiducia.nim` is a zero-dependency HTTP client using only the standard library (`std/httpclient` for transport, `std/json` for bodies), implementing the shared `PROTOCOL.md` contract; it also provides blocking `mustLock`/`lock`/`mustSemaphore`/`semaphore` acquire helpers. HTTPS targets require compiling with `-d:ssl`. The Nimble manifest and public README live one level up in `clients/nim`.
