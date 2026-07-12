# Fiducia client (Haskell) — source

Library source for the Haskell Fiducia client. `Fiducia.hs` is the single module: a thin HTTP client (http-client + http-client-tls transport, aeson for JSON, network-uri for percent-encoding) implementing the shared `PROTOCOL.md` contract, plus blocking `mustLock`/`lock`/`mustSemaphore`/`semaphore` acquire helpers. Packaging and the public README live one level up in `clients/haskell`.
