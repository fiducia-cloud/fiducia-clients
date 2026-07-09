# Fiducia HTTP client (R). Depends on httr (HTTP) + jsonlite (JSON).
# Implements PROTOCOL.md.
#
#   c   <- fiducia_client("https://api.fiducia.cloud")
#   lk  <- lock_acquire(c, "orders/checkout", ttl_ms = 30000)
#   tok <- lk$result$output$fencing_token
#   lock_release(c, "orders/checkout", "worker-a", tok)
#
# The wire protocol (paths + request bodies) is encapsulated entirely in this
# file: callers pass keys/holders, the client maps them to the HTTP contract.

# --- constructor -----------------------------------------------------------

#' Create a Fiducia client.
#'
#' Returns an S3 object (a list with class "fiducia_client") holding the
#' trimmed base URL and an optional per-request timeout (seconds).
fiducia_client <- function(base_url, timeout = 30) {
  structure(
    list(base = sub("/+$", "", base_url), timeout = timeout),
    class = "fiducia_client"
  )
}

# --- internals -------------------------------------------------------------

# Percent-encode a single value for use in a path segment or query value.
.fiducia_enc <- function(x) {
  utils::URLencode(as.character(x), reserved = TRUE)
}

# Drop NULL entries so optional params are omitted from the JSON body
# (matters for CAS semantics). FALSE / 0 / "" are kept.
.fiducia_compact <- function(x) {
  x[!vapply(x, is.null, logical(1))]
}

# Serialize a request body. Scalars are unboxed; an empty body becomes "{}"
# (some endpoints, e.g. heartbeat, expect a JSON object rather than no body).
.fiducia_json_body <- function(x) {
  if (length(x) == 0) {
    return("{}")
  }
  jsonlite::toJSON(x, auto_unbox = TRUE, null = "null", na = "null")
}

# Core request. body = NULL means "send no body" (GET / bare DELETE); a list
# (even empty) means "send a JSON body". Parses the JSON response, or NULL on
# an empty body, and raises a `fiducia_error` condition on HTTP status >= 300.
.fiducia_request <- function(client, method, path, body = NULL) {
  url <- paste0(client$base, path)
  verb_fn <- switch(
    method,
    GET = httr::GET,
    POST = httr::POST,
    PUT = httr::PUT,
    DELETE = httr::DELETE,
    stop(sprintf("fiducia: unsupported HTTP method %s", method))
  )

  args <- list(url = url)
  if (!is.null(body)) {
    args$body <- .fiducia_json_body(body)
    args$encode <- "raw"
    args <- c(args, list(httr::content_type_json()))
  }
  if (!is.null(client$timeout)) {
    args <- c(args, list(httr::timeout(client$timeout)))
  }

  resp <- do.call(verb_fn, args)
  status <- httr::status_code(resp)
  text <- httr::content(resp, as = "text", encoding = "UTF-8")
  data <- if (length(text) == 0 || is.na(text) || !nzchar(text)) {
    NULL
  } else {
    jsonlite::fromJSON(text, simplifyVector = FALSE)
  }

  if (status >= 300) {
    stop(structure(
      class = c("fiducia_error", "error", "condition"),
      list(
        message = sprintf("fiducia: HTTP %d", status),
        status = status,
        body = data
      )
    ))
  }
  data
}

# --- misc ------------------------------------------------------------------

health <- function(client) {
  .fiducia_request(client, "GET", "/healthz")
}

status <- function(client) {
  .fiducia_request(client, "GET", "/v1/status")
}

# --- locks (single-key + multi-key UNION locks) ----------------------------

lock_get <- function(client, key) {
  .fiducia_request(client, "GET", paste0("/v1/locks?key=", .fiducia_enc(key)))
}

lock_acquire <- function(client, key, holder = NULL, ttl_ms = NULL, wait = TRUE) {
  body <- .fiducia_compact(list(key = key, holder = holder, ttl_ms = ttl_ms, wait = wait))
  .fiducia_request(client, "POST", "/v1/locks/acquire", body)
}

lock_acquire_many <- function(client, keys, holder = NULL, ttl_ms = NULL, wait = TRUE) {
  # Multi-key UNION lock: all-or-nothing across the whole set. as.list keeps a
  # single key as a JSON array rather than unboxing it to a scalar.
  body <- .fiducia_compact(list(
    keys = as.list(as.character(keys)),
    holder = holder, ttl_ms = ttl_ms, wait = wait
  ))
  .fiducia_request(client, "POST", "/v1/locks/acquire", body)
}

try_lock <- function(client, key, holder = NULL, ttl_ms = NULL) {
  lock_acquire(client, key, holder = holder, ttl_ms = ttl_ms, wait = FALSE)
}

must_lock <- function(client, key, holder = NULL, ttl_ms = NULL) {
  lock_acquire(client, key, holder = holder, ttl_ms = ttl_ms, wait = TRUE)
}

# Alias for must_lock.
lock <- function(client, key, holder = NULL, ttl_ms = NULL) {
  must_lock(client, key, holder = holder, ttl_ms = ttl_ms)
}

# `key` is accepted for symmetry but a grant is released by its fencing token.
lock_release <- function(client, key, holder, fencing_token) {
  body <- .fiducia_compact(list(holder = holder, fencing_token = fencing_token))
  .fiducia_request(client, "POST", "/v1/locks/release", body)
}

# --- semaphores (counting: up to `limit` concurrent holders) ---------------

semaphore_get <- function(client, key) {
  .fiducia_request(client, "GET", paste0("/v1/semaphores?key=", .fiducia_enc(key)))
}

semaphore_acquire <- function(client, key, limit, holder = NULL, ttl_ms = NULL, wait = TRUE) {
  body <- .fiducia_compact(list(
    key = key, holder = holder, ttl_ms = ttl_ms, limit = limit, wait = wait
  ))
  .fiducia_request(client, "POST", "/v1/semaphores/acquire", body)
}

try_semaphore <- function(client, key, limit, holder = NULL, ttl_ms = NULL) {
  semaphore_acquire(client, key, limit, holder = holder, ttl_ms = ttl_ms, wait = FALSE)
}

must_semaphore <- function(client, key, limit, holder = NULL, ttl_ms = NULL) {
  semaphore_acquire(client, key, limit, holder = holder, ttl_ms = ttl_ms, wait = TRUE)
}

# Alias for must_semaphore.
semaphore <- function(client, key, limit, holder = NULL, ttl_ms = NULL) {
  must_semaphore(client, key, limit, holder = holder, ttl_ms = ttl_ms)
}

semaphore_release <- function(client, key, holder, fencing_token) {
  body <- .fiducia_compact(list(key = key, holder = holder, fencing_token = fencing_token))
  .fiducia_request(client, "POST", "/v1/semaphores/release", body)
}

# --- idempotency keys ------------------------------------------------------

idempotency_get <- function(client, key) {
  .fiducia_request(client, "GET", paste0("/v1/idempotency?key=", .fiducia_enc(key)))
}

idempotency_claim <- function(client, key, owner = NULL, ttl_ms = NULL, ttl = NULL, metadata = NULL) {
  body <- .fiducia_compact(list(
    key = key, owner = owner, ttl_ms = ttl_ms, ttl = ttl, metadata = metadata
  ))
  .fiducia_request(client, "POST", "/v1/idempotency/claim", body)
}

idempotency_complete <- function(client, key, owner, fencing_token, result = NULL) {
  body <- .fiducia_compact(list(
    key = key, owner = owner, fencing_token = fencing_token, result = result
  ))
  .fiducia_request(client, "POST", "/v1/idempotency/complete", body)
}

# --- reader-writer locks ---------------------------------------------------

rw_acquire_read <- function(client, key, ttl_ms = NULL, wait = TRUE) {
  body <- .fiducia_compact(list(ttl_ms = ttl_ms, wait = wait))
  .fiducia_request(client, "POST", paste0("/v1/rw/", .fiducia_enc(key), "/read"), body)
}

rw_end_read <- function(client, key, lock_id) {
  body <- .fiducia_compact(list(lock_id = lock_id))
  .fiducia_request(client, "POST", paste0("/v1/rw/", .fiducia_enc(key), "/read/end"), body)
}

rw_acquire_write <- function(client, key, ttl_ms = NULL, wait = TRUE) {
  body <- .fiducia_compact(list(ttl_ms = ttl_ms, wait = wait))
  .fiducia_request(client, "POST", paste0("/v1/rw/", .fiducia_enc(key), "/write"), body)
}

rw_end_write <- function(client, key, lock_id) {
  body <- .fiducia_compact(list(lock_id = lock_id))
  .fiducia_request(client, "POST", paste0("/v1/rw/", .fiducia_enc(key), "/write/end"), body)
}

# --- config KV (keys are ?key=, slash-safe) --------------------------------

kv_get <- function(client, key) {
  .fiducia_request(client, "GET", paste0("/v1/kv?key=", .fiducia_enc(key)))
}

kv_put <- function(client, key, value, ttl_ms = NULL, prev_revision = NULL) {
  body <- .fiducia_compact(list(value = value, ttl_ms = ttl_ms, prev_revision = prev_revision))
  .fiducia_request(client, "PUT", paste0("/v1/kv?key=", .fiducia_enc(key)), body)
}

kv_delete <- function(client, key) {
  .fiducia_request(client, "DELETE", paste0("/v1/kv?key=", .fiducia_enc(key)))
}

kv_list <- function(client, prefix) {
  .fiducia_request(client, "GET", paste0("/v1/kv?prefix=", .fiducia_enc(prefix)))
}

# --- rate limiting ---------------------------------------------------------

rate_limit_get <- function(client, tenant, key) {
  .fiducia_request(
    client, "GET",
    paste0("/v1/rate-limit/", .fiducia_enc(tenant), "/", .fiducia_enc(key))
  )
}

rate_limit_check <- function(client, tenant, key, algorithm, limit, window_ms,
                             refill_per_second = NULL, cost = NULL) {
  body <- .fiducia_compact(list(
    algorithm = algorithm, limit = limit, window_ms = window_ms,
    refill_per_second = refill_per_second, cost = cost
  ))
  .fiducia_request(
    client, "POST",
    paste0("/v1/rate-limit/", .fiducia_enc(tenant), "/", .fiducia_enc(key), "/check"),
    body
  )
}

# --- cron / scheduling -----------------------------------------------------

schedule_get <- function(client, name) {
  .fiducia_request(client, "GET", paste0("/v1/cron/schedules/", .fiducia_enc(name)))
}

schedule_upsert <- function(client, name, target, cron = NULL, one_shot_at_ms = NULL,
                            delivery = NULL, max_retries = NULL) {
  body <- .fiducia_compact(list(
    target = target, cron = cron, one_shot_at_ms = one_shot_at_ms,
    delivery = delivery, max_retries = max_retries
  ))
  .fiducia_request(client, "PUT", paste0("/v1/cron/schedules/", .fiducia_enc(name)), body)
}

schedule_record_run <- function(client, name, fire_id, fired_at_ms = NULL) {
  body <- .fiducia_compact(list(fire_id = fire_id, fired_at_ms = fired_at_ms))
  .fiducia_request(
    client, "POST",
    paste0("/v1/cron/schedules/", .fiducia_enc(name), "/runs"), body
  )
}

schedule_history <- function(client, name) {
  .fiducia_request(client, "GET", paste0("/v1/cron/schedules/", .fiducia_enc(name), "/history"))
}

# --- leader election -------------------------------------------------------

election_get <- function(client, name) {
  .fiducia_request(client, "GET", paste0("/v1/elections/", .fiducia_enc(name)))
}

election_campaign <- function(client, name, candidate, ttl_ms, metadata = NULL) {
  body <- .fiducia_compact(list(candidate = candidate, ttl_ms = ttl_ms, metadata = metadata))
  .fiducia_request(
    client, "POST",
    paste0("/v1/elections/", .fiducia_enc(name), "/campaign"), body
  )
}

election_renew <- function(client, name, candidate, fencing_token) {
  body <- .fiducia_compact(list(candidate = candidate, fencing_token = fencing_token))
  .fiducia_request(
    client, "POST",
    paste0("/v1/elections/", .fiducia_enc(name), "/renew"), body
  )
}

election_resign <- function(client, name, candidate, fencing_token) {
  body <- .fiducia_compact(list(candidate = candidate, fencing_token = fencing_token))
  .fiducia_request(
    client, "POST",
    paste0("/v1/elections/", .fiducia_enc(name), "/resign"), body
  )
}

# --- service discovery -----------------------------------------------------

service_instances <- function(client, service) {
  .fiducia_request(client, "GET", paste0("/v1/services/", .fiducia_enc(service)))
}

service_register <- function(client, service, instance_id, address, ttl_ms, metadata = NULL) {
  body <- .fiducia_compact(list(address = address, ttl_ms = ttl_ms, metadata = metadata))
  .fiducia_request(
    client, "PUT",
    paste0("/v1/services/", .fiducia_enc(service), "/instances/", .fiducia_enc(instance_id)),
    body
  )
}

service_heartbeat <- function(client, service, instance_id, ttl_ms = NULL) {
  # Always send a JSON body — the node's heartbeat handler expects one.
  body <- .fiducia_compact(list(ttl_ms = ttl_ms))
  .fiducia_request(
    client, "POST",
    paste0("/v1/services/", .fiducia_enc(service), "/instances/",
           .fiducia_enc(instance_id), "/heartbeat"),
    body
  )
}

service_deregister <- function(client, service, instance_id) {
  .fiducia_request(
    client, "DELETE",
    paste0("/v1/services/", .fiducia_enc(service), "/instances/", .fiducia_enc(instance_id))
  )
}

service_list <- function(client) {
  .fiducia_request(client, "GET", "/v1/services")
}
