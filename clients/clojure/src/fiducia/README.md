# fiducia (Clojure source)

The `fiducia.client` namespace — the entire Clojure client in one file, `client.clj`.
It wraps the fiducia.cloud coordination API (locks, semaphores, idempotency, config
KV, rate limiting, cron, leader election, service discovery) over the shared
`PROTOCOL.md` contract, using only the JDK's `java.net.http.HttpClient` for transport
and `org.clojure/data.json` for JSON. Build a client with `client`, then pass it first
to every operation. Redirects are never followed so a 3xx can't silently re-submit a
mutating request.
