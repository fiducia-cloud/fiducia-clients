;; Fiducia HTTP client (Clojure). Transport: JDK java.net.http.HttpClient (JDK 11+).
;; JSON: org.clojure/data.json. Implements PROTOCOL.md.
;;
;;   (require '[fiducia.client :as f])
;;   (def c (f/client "https://api.fiducia.cloud"))
;;   (def lk (f/lock-acquire c "orders/checkout" {:ttl_ms 30000}))
;;   (f/lock-release c "orders/checkout" "worker-a"
;;                   (get-in lk [:result :output :fencing_token]))

(ns fiducia.client
  (:require [clojure.data.json :as json]
            [clojure.string :as str])
  (:import [java.net URI URLEncoder]
           [java.net.http HttpClient HttpClient$Builder HttpClient$Redirect
            HttpRequest HttpRequest$Builder HttpRequest$BodyPublishers
            HttpResponse HttpResponse$BodyHandlers]
           [java.time Duration]))

;; A Fiducia client. Build one with `client`; pass it first to every op.
(defrecord Client [base http timeout-ms])

;; Conservative default so a request can never hang forever. These ops do not
;; long-poll, so a bounded default is safe; callers can still override per client.
(def ^:private default-timeout-ms 30000)

(defn client
  "Build a Fiducia client.

     (client \"https://api.fiducia.cloud\")
     (client \"https://api.fiducia.cloud\" {:timeout-ms 5000 :connect-timeout-ms 2000})

   The trailing slash of the base URL is trimmed. Options (both default to 30000 ms):
     :timeout-ms         per-request read/response timeout (ms)
     :connect-timeout-ms TCP connect timeout (ms)

   Redirects are never followed: a 3xx surfaces as an error like any other
   status >= 300, so a redirect can never silently re-submit a mutating
   POST/PUT/DELETE (which could duplicate a lock grant / queue slot)."
  ([base-url] (client base-url nil))
  ([base-url opts]
   (let [base (str/replace (str base-url) #"/+$" "")
         connect-ms (get opts :connect-timeout-ms default-timeout-ms)
         ^HttpClient$Builder builder (HttpClient/newBuilder)]
     (.followRedirects builder HttpClient$Redirect/NEVER)
     (.connectTimeout builder (Duration/ofMillis (long connect-ms)))
     (->Client base (.build builder) (get opts :timeout-ms default-timeout-ms)))))

;; ---------------------------------------------------------------------------
;; internals
;; ---------------------------------------------------------------------------

(defn- enc
  "Percent-encode `s` for use in a path segment or query value."
  [s]
  (-> (URLEncoder/encode (str s) "UTF-8")
      (.replace "+" "%20")))

(defn- compact
  "Drop map entries whose value is nil (keeps false, 0, \"\", {} ...)."
  [m]
  (into {} (remove (comp nil? val) m)))

(defn- request
  ([c method path] (request c method path nil))
  ([c method path body]
   (let [uri (URI/create (str (:base c) path))
         ^HttpRequest$Builder builder (HttpRequest/newBuilder)
         publisher (if (nil? body)
                     (HttpRequest$BodyPublishers/noBody)
                     (HttpRequest$BodyPublishers/ofString (json/write-str body)))]
     (.uri builder uri)
     (when-let [t (:timeout-ms c)]
       (.timeout builder (Duration/ofMillis (long t))))
     (when (some? body)
       (.header builder "content-type" "application/json"))
     (case method
       :get    (.GET builder)
       :delete (.DELETE builder)
       :post   (.POST builder publisher)
       :put    (.PUT builder publisher))
     (let [^HttpResponse resp (.send ^HttpClient (:http c)
                                     (.build builder)
                                     (HttpResponse$BodyHandlers/ofString))
           status (.statusCode resp)
           ^String raw (.body resp)
           data (when-not (str/blank? raw)
                  ;; A non-JSON body (e.g. a proxy's plain-text 5xx) must not
                  ;; crash the client: fall back to the raw text.
                  (try (json/read-str raw :key-fn keyword)
                       (catch Exception _ raw)))]
       (when (>= status 300)
         (throw (ex-info (str "fiducia: HTTP " status)
                         {:status status :body data})))
       data))))

;; ---------------------------------------------------------------------------
;; misc
;; ---------------------------------------------------------------------------

(defn health [c] (request c :get "/healthz"))
(defn status [c] (request c :get "/v1/status"))

;; ---------------------------------------------------------------------------
;; locks
;; ---------------------------------------------------------------------------

(defn lock-get [c key]
  (request c :get (str "/v1/locks?key=" (enc key))))

(defn lock-acquire
  "Acquire a single-key lock. opts: :holder :ttl_ms :wait (default true)."
  ([c key] (lock-acquire c key nil))
  ([c key opts]
   (request c :post "/v1/locks/acquire"
            (merge {:key key :wait (get opts :wait true)}
                   (compact {:holder (:holder opts) :ttl_ms (:ttl_ms opts)})))))

(defn lock-acquire-many
  "Acquire a union lock over `keys` (a seq of strings). opts as `lock-acquire`."
  ([c keys] (lock-acquire-many c keys nil))
  ([c keys opts]
   (request c :post "/v1/locks/acquire"
            (merge {:keys (vec keys) :wait (get opts :wait true)}
                   (compact {:holder (:holder opts) :ttl_ms (:ttl_ms opts)})))))

(defn try-lock
  "Non-blocking acquire (wait=false)."
  ([c key] (try-lock c key nil))
  ([c key opts] (lock-acquire c key (assoc opts :wait false))))

(defn must-lock
  "Blocking acquire (wait=true)."
  ([c key] (must-lock c key nil))
  ([c key opts] (lock-acquire c key (assoc opts :wait true))))

(def ^{:doc "Alias for `must-lock` (blocking acquire)."} lock must-lock)

(defn lock-release
  "Release a lock. `key` is accepted for symmetry but is NOT sent in the body."
  [c key holder fencing-token]
  (request c :post "/v1/locks/release"
           {:holder holder :fencing_token fencing-token}))

;; ---------------------------------------------------------------------------
;; semaphores
;; ---------------------------------------------------------------------------

(defn semaphore-get [c key]
  (request c :get (str "/v1/semaphores?key=" (enc key))))

(defn semaphore-acquire
  "Acquire a semaphore permit. opts: :holder :ttl_ms :wait (default true)."
  ([c key limit] (semaphore-acquire c key limit nil))
  ([c key limit opts]
   (request c :post "/v1/semaphores/acquire"
            (merge {:key key :limit limit :wait (get opts :wait true)}
                   (compact {:holder (:holder opts) :ttl_ms (:ttl_ms opts)})))))

(defn try-semaphore
  ([c key limit] (try-semaphore c key limit nil))
  ([c key limit opts] (semaphore-acquire c key limit (assoc opts :wait false))))

(defn must-semaphore
  ([c key limit] (must-semaphore c key limit nil))
  ([c key limit opts] (semaphore-acquire c key limit (assoc opts :wait true))))

(def ^{:doc "Alias for `must-semaphore` (blocking acquire)."} semaphore must-semaphore)

(defn semaphore-release [c key holder fencing-token]
  (request c :post "/v1/semaphores/release"
           {:key key :holder holder :fencing_token fencing-token}))

;; ---------------------------------------------------------------------------
;; idempotency
;; ---------------------------------------------------------------------------

(defn idempotency-get [c key]
  (request c :get (str "/v1/idempotency?key=" (enc key))))

(defn idempotency-claim
  "opts: :owner :ttl_ms :ttl :metadata (arbitrary JSON object)."
  ([c key] (idempotency-claim c key nil))
  ([c key opts]
   (request c :post "/v1/idempotency/claim"
            (merge {:key key}
                   (compact {:owner (:owner opts) :ttl_ms (:ttl_ms opts)
                             :ttl (:ttl opts) :metadata (:metadata opts)})))))

(defn idempotency-complete
  "opts: :result (arbitrary JSON object)."
  ([c key owner fencing-token] (idempotency-complete c key owner fencing-token nil))
  ([c key owner fencing-token opts]
   (request c :post "/v1/idempotency/complete"
            (merge {:key key :owner owner :fencing_token fencing-token}
                   (compact {:result (:result opts)})))))

;; ---------------------------------------------------------------------------
;; reader-writer locks
;; ---------------------------------------------------------------------------

(defn rw-acquire-read
  ([c key] (rw-acquire-read c key nil))
  ([c key opts]
   (request c :post (str "/v1/rw/" (enc key) "/read")
            (merge {:wait (get opts :wait true)}
                   (compact {:ttl_ms (:ttl_ms opts)})))))

(defn rw-end-read [c key lock-id]
  (request c :post (str "/v1/rw/" (enc key) "/read/end")
           {:lock_id lock-id}))

(defn rw-acquire-write
  ([c key] (rw-acquire-write c key nil))
  ([c key opts]
   (request c :post (str "/v1/rw/" (enc key) "/write")
            (merge {:wait (get opts :wait true)}
                   (compact {:ttl_ms (:ttl_ms opts)})))))

(defn rw-end-write [c key lock-id]
  (request c :post (str "/v1/rw/" (enc key) "/write/end")
           {:lock_id lock-id}))

;; ---------------------------------------------------------------------------
;; config KV
;; ---------------------------------------------------------------------------

(defn kv-get [c key]
  (request c :get (str "/v1/kv?key=" (enc key))))

(defn kv-put
  "opts: :ttl_ms :prev_revision (CAS)."
  ([c key value] (kv-put c key value nil))
  ([c key value opts]
   (request c :put (str "/v1/kv?key=" (enc key))
            (merge {:value value}
                   (compact {:ttl_ms (:ttl_ms opts)
                             :prev_revision (:prev_revision opts)})))))

(defn kv-delete [c key]
  (request c :delete (str "/v1/kv?key=" (enc key))))

(defn kv-list [c prefix]
  (request c :get (str "/v1/kv?prefix=" (enc prefix))))

;; ---------------------------------------------------------------------------
;; rate limiting
;; ---------------------------------------------------------------------------

(defn rate-limit-get [c tenant key]
  (request c :get (str "/v1/rate-limit/" (enc tenant) "/" (enc key))))

(defn rate-limit-check
  "opts: :refill_per_second :cost."
  ([c tenant key algorithm limit window-ms]
   (rate-limit-check c tenant key algorithm limit window-ms nil))
  ([c tenant key algorithm limit window-ms opts]
   (request c :post (str "/v1/rate-limit/" (enc tenant) "/" (enc key) "/check")
            (merge {:algorithm algorithm :limit limit :window_ms window-ms}
                   (compact {:refill_per_second (:refill_per_second opts)
                             :cost (:cost opts)})))))

;; ---------------------------------------------------------------------------
;; cron & scheduling
;; ---------------------------------------------------------------------------

(defn schedule-get [c name]
  (request c :get (str "/v1/cron/schedules/" (enc name))))

(defn schedule-upsert
  "`target` is an arbitrary JSON object, e.g. {:kind \"webhook\" :url \"...\"}.
   opts: :cron :one_shot_at_ms :delivery :max_retries."
  ([c name target] (schedule-upsert c name target nil))
  ([c name target opts]
   (request c :put (str "/v1/cron/schedules/" (enc name))
            (merge {:target target}
                   (compact {:cron (:cron opts)
                             :one_shot_at_ms (:one_shot_at_ms opts)
                             :delivery (:delivery opts)
                             :max_retries (:max_retries opts)})))))

(defn schedule-record-run
  "opts: :fired_at_ms."
  ([c name fire-id] (schedule-record-run c name fire-id nil))
  ([c name fire-id opts]
   (request c :post (str "/v1/cron/schedules/" (enc name) "/runs")
            (merge {:fire_id fire-id}
                   (compact {:fired_at_ms (:fired_at_ms opts)})))))

(defn schedule-history [c name]
  (request c :get (str "/v1/cron/schedules/" (enc name) "/history")))

;; ---------------------------------------------------------------------------
;; leader election
;; ---------------------------------------------------------------------------

(defn election-get [c name]
  (request c :get (str "/v1/elections/" (enc name))))

(defn election-campaign
  "opts: :metadata."
  ([c name candidate ttl-ms] (election-campaign c name candidate ttl-ms nil))
  ([c name candidate ttl-ms opts]
   (request c :post (str "/v1/elections/" (enc name) "/campaign")
            (merge {:candidate candidate :ttl_ms ttl-ms}
                   (compact {:metadata (:metadata opts)})))))

(defn election-renew [c name candidate fencing-token]
  (request c :post (str "/v1/elections/" (enc name) "/renew")
           {:candidate candidate :fencing_token fencing-token}))

(defn election-resign [c name candidate fencing-token]
  (request c :post (str "/v1/elections/" (enc name) "/resign")
           {:candidate candidate :fencing_token fencing-token}))

;; ---------------------------------------------------------------------------
;; service discovery
;; ---------------------------------------------------------------------------

(defn service-instances [c service]
  (request c :get (str "/v1/services/" (enc service))))

(defn service-register
  "opts: :metadata."
  ([c service instance-id address ttl-ms]
   (service-register c service instance-id address ttl-ms nil))
  ([c service instance-id address ttl-ms opts]
   (request c :put (str "/v1/services/" (enc service) "/instances/" (enc instance-id))
            (merge {:address address :ttl_ms ttl-ms}
                   (compact {:metadata (:metadata opts)})))))

(defn service-heartbeat
  "opts: :ttl_ms."
  ([c service instance-id] (service-heartbeat c service instance-id nil))
  ([c service instance-id opts]
   (request c :post (str "/v1/services/" (enc service) "/instances/" (enc instance-id) "/heartbeat")
            (compact {:ttl_ms (:ttl_ms opts)}))))

(defn service-deregister [c service instance-id]
  (request c :delete (str "/v1/services/" (enc service) "/instances/" (enc instance-id))))

(defn service-list [c]
  (request c :get "/v1/services"))
