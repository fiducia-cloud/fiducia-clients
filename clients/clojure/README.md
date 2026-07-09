# Fiducia client (Clojure)

Thin, dependency-light HTTP client for [fiducia.cloud](https://fiducia.cloud):
distributed locks, semaphores, reader-writer locks, idempotency keys, config KV,
rate limiting, cron scheduling, leader election, and service discovery.

Transport is the JDK's `java.net.http.HttpClient` (JDK 11+); JSON is handled by
`org.clojure/data.json`. Implements `PROTOCOL.md`.

## Install

`deps.edn`:

```clojure
cloud.fiducia/fiducia-client {:mvn/version "0.1.0"}
```

Leiningen:

```clojure
[cloud.fiducia/fiducia-client "0.1.0"]
```

The only runtime dependency is `org.clojure/data.json` (HTTP uses the JDK).

## Usage

```clojure
(require '[fiducia.client :as f])

(def c (f/client "https://api.fiducia.cloud"))
;; with optional timeouts:
;; (def c (f/client "https://api.fiducia.cloud" {:timeout-ms 5000 :connect-timeout-ms 2000}))

(f/health c)
(f/status c)

;; Locks
(def lk  (f/lock-acquire c "orders/checkout" {:ttl_ms 30000}))
(def tok (get-in lk [:result :output :fencing_token]))
(f/lock-release c "orders/checkout" "worker-a" tok)

;; try-lock: single, non-blocking shot (wait=false) — raw acquire response
(f/try-lock  c "orders/checkout")

;; must-lock / lock: BLOCK until actually held (reserve slot + poll), or time out.
;; Returns a held-grant map you can release directly:
(let [g (f/must-lock c "orders/checkout" {:max_wait_ms 30000 :retry_interval_ms 250})]
  (f/lock-release c (:key g) (:holder g) (:fencing_token g)))
;; (f/lock c "orders/checkout") is an alias of must-lock.

(f/lock-acquire-many c ["a" "b" "c"] {:ttl_ms 10000})  ; union lock (single shot)

;; A sampling of the rest
(f/semaphore-acquire c "pool/db" 5 {:ttl_ms 10000})
(f/kv-put c "cfg/flag" {:enabled true})
(f/kv-get c "cfg/flag")
(f/election-campaign c "leader/report" "node-1" 15000)
(f/service-register  c "api" "api-1" "10.0.0.1:8080" 30000)
(f/rate-limit-check  c "acme" "login" "token_bucket" 100 60000 {:refill_per_second 10})
(f/idempotency-claim c "charge:42" {:owner "worker-a" :ttl_ms 60000})
```

Every op takes the client first and returns the parsed JSON as Clojure data with
keyword keys (or `nil` for an empty body). Optional arguments go in a trailing
options map; only the keys you actually pass are placed in the request body (so
compare-and-set semantics like `:prev_revision` behave correctly).

## Errors

On HTTP status `>= 300` the client throws an `ex-info`:

```clojure
(try
  (f/lock-get c "missing")
  (catch clojure.lang.ExceptionInfo e
    (:status (ex-data e))    ; => numeric HTTP status
    (:body   (ex-data e))))  ; => parsed JSON body (keywordized) or nil
```

## Method surface

- misc: `health` `status`
- locks: `lock-get` `lock-acquire` `lock-acquire-many` `try-lock` `must-lock` `lock` `lock-release`
- semaphores: `semaphore-get` `semaphore-acquire` `try-semaphore` `must-semaphore` `semaphore` `semaphore-release`
- idempotency: `idempotency-get` `idempotency-claim` `idempotency-complete`
- reader-writer locks: `rw-acquire-read` `rw-end-read` `rw-acquire-write` `rw-end-write`
- config KV: `kv-get` `kv-put` `kv-delete` `kv-list`
- rate limiting: `rate-limit-get` `rate-limit-check`
- cron & scheduling: `schedule-get` `schedule-upsert` `schedule-record-run` `schedule-history`
- leader election: `election-get` `election-campaign` `election-renew` `election-resign`
- service discovery: `service-instances` `service-register` `service-heartbeat` `service-deregister` `service-list`

## Publishing

Published to [Clojars](https://clojars.org) with `deps-deploy` via `tools.build`:

```sh
clojure -T:build jar       # build the jar under target/
clojure -T:build deploy    # deploy (needs CLOJARS_USERNAME / CLOJARS_PASSWORD)
```
