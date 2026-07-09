/*
 * Fiducia HTTP client (C11), built on libcurl. Implements PROTOCOL.md.
 *
 * C has no standard JSON library, so this client does NOT parse responses: it
 * returns the raw status code + response body and you bring your own JSON
 * parser. Non-2xx is NOT an error at this layer -- inspect `out.status`.
 *
 *   #include "fiducia.h"
 *   fiducia_client *c = fiducia_client_new("https://api.fiducia.cloud");
 *   fiducia_response r;
 *   if (fiducia_lock_acquire(c, "orders/checkout", "worker-a", 30000, 0, &r) == 0
 *       && r.status < 300) {
 *       ... parse r.body with your JSON lib, release with the fencing_token ...
 *   }
 *   fiducia_response_free(&r);
 *   fiducia_client_free(c);
 *
 * Dependency: libcurl (link with -lcurl). Version: 0.1.0. License: UNLICENSED.
 */
#ifndef FIDUCIA_H
#define FIDUCIA_H

#include <stddef.h> /* size_t */

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Result codes returned by every operation.
 *
 * A return of 0 (FIDUCIA_OK) means the HTTP round-trip completed; you must then
 * inspect `out->status` for the HTTP status code -- a 4xx/5xx is a *successful*
 * round-trip at this layer, not a transport error. A negative return means the
 * request never reached a server (bad argument, out of memory, or a libcurl
 * transport failure); in that case `out->status` is 0 and `out->body` is NULL.
 */
enum {
    FIDUCIA_OK = 0,             /* HTTP round-trip completed; see out->status */
    FIDUCIA_ERR_ARG = -1,       /* a required pointer argument was NULL */
    FIDUCIA_ERR_MEMORY = -2,    /* out of memory while building the request */
    FIDUCIA_ERR_TRANSPORT = -3  /* libcurl could not complete the request */
};

/*
 * The outcome of one request. `body` is a heap-allocated, NUL-terminated copy
 * of the response body, or NULL when the body was empty. Always release it with
 * fiducia_response_free() (safe to call even after a negative return).
 */
typedef struct {
    long status; /* HTTP status code, or 0 if the request never completed */
    char *body;  /* NUL-terminated response body, may be NULL */
} fiducia_response;

/* Free `out->body` and reset the struct. Safe on NULL and on zeroed structs. */
void fiducia_response_free(fiducia_response *out);

/* Opaque client handle. */
typedef struct fiducia_client fiducia_client;

/*
 * Create a client for `base_url` (trailing slashes are trimmed). Returns NULL on
 * allocation failure or if `base_url` is NULL. The first call also performs a
 * one-time curl_global_init(CURL_GLOBAL_DEFAULT); in a multi-threaded program
 * call curl_global_init() yourself before spawning threads (a libcurl rule).
 */
fiducia_client *fiducia_client_new(const char *base_url);

/* Destroy a client. Safe on NULL. */
void fiducia_client_free(fiducia_client *c);

/* Optional per-request timeout in milliseconds (<= 0 disables; the default). */
void fiducia_client_set_timeout_ms(fiducia_client *c, long timeout_ms);

/* Library version string, e.g. "0.1.0". */
const char *fiducia_version(void);

/*
 * Conventions shared by every operation below:
 *   - `out` receives the response and must not be NULL.
 *   - `holder`/`owner`/`candidate`/optional string params: pass NULL to omit.
 *   - Optional `ttl_ms`: pass <= 0 to omit the field.
 *   - Other optional numbers (prev_revision, cost, one_shot_at_ms, fired_at_ms,
 *     max_retries, refill_per_second): pass a negative value to omit (0 is sent).
 *   - `*_json` params (metadata/target/result): a raw JSON *object* string that
 *     is copied through verbatim -- YOU must ensure it is valid JSON. NULL omits.
 *   - Every interpolated key/name/service/instance_id/tenant/prefix is
 *     percent-encoded for you.
 */

/* --- misc --- */
int fiducia_health(fiducia_client *c, fiducia_response *out);
int fiducia_status(fiducia_client *c, fiducia_response *out);

/* --- locks --- */
int fiducia_lock_get(fiducia_client *c, const char *key, fiducia_response *out);
int fiducia_lock_acquire(fiducia_client *c, const char *key, const char *holder,
                         long ttl_ms, int wait, fiducia_response *out);
int fiducia_lock_acquire_many(fiducia_client *c, const char *const *keys,
                              size_t n_keys, const char *holder, long ttl_ms,
                              int wait, fiducia_response *out);
int fiducia_try_lock(fiducia_client *c, const char *key, const char *holder,
                     long ttl_ms, fiducia_response *out);
int fiducia_must_lock(fiducia_client *c, const char *key, const char *holder,
                      long ttl_ms, fiducia_response *out);
/* Alias of fiducia_must_lock (wait = true). */
int fiducia_lock(fiducia_client *c, const char *key, const char *holder,
                 long ttl_ms, fiducia_response *out);
/* `key` is accepted for symmetry but is NOT sent in the body. */
int fiducia_lock_release(fiducia_client *c, const char *key, const char *holder,
                         long fencing_token, fiducia_response *out);

/* --- semaphores --- */
int fiducia_semaphore_get(fiducia_client *c, const char *key,
                          fiducia_response *out);
int fiducia_semaphore_acquire(fiducia_client *c, const char *key, long limit,
                              const char *holder, long ttl_ms, int wait,
                              fiducia_response *out);
int fiducia_try_semaphore(fiducia_client *c, const char *key, long limit,
                          const char *holder, long ttl_ms, fiducia_response *out);
int fiducia_must_semaphore(fiducia_client *c, const char *key, long limit,
                           const char *holder, long ttl_ms,
                           fiducia_response *out);
/* Alias of fiducia_must_semaphore (wait = true). */
int fiducia_semaphore(fiducia_client *c, const char *key, long limit,
                      const char *holder, long ttl_ms, fiducia_response *out);
int fiducia_semaphore_release(fiducia_client *c, const char *key,
                              const char *holder, long fencing_token,
                              fiducia_response *out);

/* --- idempotency keys --- */
int fiducia_idempotency_get(fiducia_client *c, const char *key,
                            fiducia_response *out);
int fiducia_idempotency_claim(fiducia_client *c, const char *key,
                              const char *owner, long ttl_ms, const char *ttl,
                              const char *metadata_json, fiducia_response *out);
int fiducia_idempotency_complete(fiducia_client *c, const char *key,
                                 const char *owner, long fencing_token,
                                 const char *result_json, fiducia_response *out);

/* --- reader-writer locks --- */
int fiducia_rw_acquire_read(fiducia_client *c, const char *key, long ttl_ms,
                            int wait, fiducia_response *out);
int fiducia_rw_end_read(fiducia_client *c, const char *key, const char *lock_id,
                        fiducia_response *out);
int fiducia_rw_acquire_write(fiducia_client *c, const char *key, long ttl_ms,
                             int wait, fiducia_response *out);
int fiducia_rw_end_write(fiducia_client *c, const char *key, const char *lock_id,
                         fiducia_response *out);

/* --- config KV --- */
int fiducia_kv_get(fiducia_client *c, const char *key, fiducia_response *out);
int fiducia_kv_put(fiducia_client *c, const char *key, const char *value,
                   long ttl_ms, long prev_revision, fiducia_response *out);
int fiducia_kv_delete(fiducia_client *c, const char *key, fiducia_response *out);
int fiducia_kv_list(fiducia_client *c, const char *prefix, fiducia_response *out);

/* --- rate limiting --- */
int fiducia_rate_limit_get(fiducia_client *c, const char *tenant,
                           const char *key, fiducia_response *out);
int fiducia_rate_limit_check(fiducia_client *c, const char *tenant,
                             const char *key, const char *algorithm, long limit,
                             long window_ms, double refill_per_second, long cost,
                             fiducia_response *out);

/* --- cron & scheduling --- */
int fiducia_schedule_get(fiducia_client *c, const char *name,
                         fiducia_response *out);
int fiducia_schedule_upsert(fiducia_client *c, const char *name,
                            const char *target_json, const char *cron,
                            long one_shot_at_ms, const char *delivery,
                            long max_retries, fiducia_response *out);
int fiducia_schedule_record_run(fiducia_client *c, const char *name,
                                const char *fire_id, long fired_at_ms,
                                fiducia_response *out);
int fiducia_schedule_history(fiducia_client *c, const char *name,
                             fiducia_response *out);

/* --- leader election --- */
int fiducia_election_get(fiducia_client *c, const char *name,
                         fiducia_response *out);
int fiducia_election_campaign(fiducia_client *c, const char *name,
                              const char *candidate, long ttl_ms,
                              const char *metadata_json, fiducia_response *out);
int fiducia_election_renew(fiducia_client *c, const char *name,
                           const char *candidate, long fencing_token,
                           fiducia_response *out);
int fiducia_election_resign(fiducia_client *c, const char *name,
                            const char *candidate, long fencing_token,
                            fiducia_response *out);

/* --- service discovery --- */
int fiducia_service_instances(fiducia_client *c, const char *service,
                              fiducia_response *out);
int fiducia_service_register(fiducia_client *c, const char *service,
                             const char *instance_id, const char *address,
                             long ttl_ms, const char *metadata_json,
                             fiducia_response *out);
int fiducia_service_heartbeat(fiducia_client *c, const char *service,
                              const char *instance_id, long ttl_ms,
                              fiducia_response *out);
int fiducia_service_deregister(fiducia_client *c, const char *service,
                               const char *instance_id, fiducia_response *out);
int fiducia_service_list(fiducia_client *c, fiducia_response *out);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* FIDUCIA_H */
