/*
 * Fiducia HTTP client (C11), built on libcurl. Implements PROTOCOL.md.
 *
 * No JSON parsing: each op fills a fiducia_response (status + raw body) and
 * returns 0 on a completed round-trip (negative on transport failure). Request
 * bodies are built by hand; path/query values are escaped with curl_easy_escape.
 *
 *   fiducia_client *c = fiducia_client_new("https://api.fiducia.cloud");
 *   fiducia_response r;
 *   fiducia_kv_put(c, "flags/new-ui", "on", 60000, -1, &r);
 *   fiducia_response_free(&r);
 *   fiducia_client_free(c);
 *
 * Dependency: libcurl (-lcurl). Version 0.1.0. License: UNLICENSED.
 */
#include "fiducia.h"

#include <curl/curl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define FIDUCIA_VERSION "0.1.0"

/*
 * Default per-request timeout (connect + transfer), in milliseconds. These
 * clients never long-poll -- per PROTOCOL, waiting on wait:true is client-driven
 * and the server returns immediately -- so every request completes promptly and
 * a conservative default is safe. Override, or disable with <= 0, via
 * fiducia_client_set_timeout_ms().
 */
#define FIDUCIA_DEFAULT_TIMEOUT_MS 30000L

/* --------------------------------------------------------------------------
 * Growable string buffer (for URLs and JSON bodies).
 * On allocation failure `err` latches to 1 and further appends are no-ops.
 * ------------------------------------------------------------------------ */
struct sbuf {
    char *data;
    size_t len;
    size_t cap;
    int err;
};

static void sbuf_init(struct sbuf *s) {
    s->data = NULL;
    s->len = 0;
    s->cap = 0;
    s->err = 0;
}

static int sbuf_reserve(struct sbuf *s, size_t extra) {
    if (s->err) return 0;
    /* need room for len + extra + trailing NUL; guard the size_t math so a
     * wrapped total can never fool the capacity check into under-allocating */
    if (extra > SIZE_MAX - 1 || s->len > SIZE_MAX - 1 - extra) {
        s->err = 1;
        return 0;
    }
    size_t need = s->len + extra + 1;
    if (need <= s->cap) return 1;
    size_t ncap = s->cap ? s->cap : 64;
    while (ncap < need) {
        size_t doubled = ncap * 2;
        if (doubled < ncap) { s->err = 1; return 0; } /* overflow */
        ncap = doubled;
    }
    char *nd = realloc(s->data, ncap);
    if (!nd) { s->err = 1; return 0; }
    s->data = nd;
    s->cap = ncap;
    return 1;
}

static void sbuf_putn(struct sbuf *s, const char *p, size_t n) {
    if (!sbuf_reserve(s, n)) return;
    memcpy(s->data + s->len, p, n);
    s->len += n;
    s->data[s->len] = '\0';
}

static void sbuf_puts(struct sbuf *s, const char *p) {
    if (p) sbuf_putn(s, p, strlen(p));
}

static void sbuf_putc(struct sbuf *s, char ch) { sbuf_putn(s, &ch, 1); }

static void sbuf_putlong(struct sbuf *s, long v) {
    char tmp[32];
    int n = snprintf(tmp, sizeof tmp, "%ld", v);
    if (n > 0) sbuf_putn(s, tmp, (size_t)n);
}

static void sbuf_putdouble(struct sbuf *s, double v) {
    char tmp[64];
    int n = snprintf(tmp, sizeof tmp, "%.17g", v);
    if (n <= 0) return;
    /* Guard against locales whose decimal separator is ',' -- JSON needs '.'. */
    for (int i = 0; i < n; i++) {
        if (tmp[i] == ',') tmp[i] = '.';
    }
    sbuf_putn(s, tmp, (size_t)n);
}

/* Append a JSON string literal ("...") with the required escapes. */
static void sbuf_put_json_string(struct sbuf *s, const char *p) {
    sbuf_putc(s, '"');
    if (p) {
        for (const unsigned char *u = (const unsigned char *)p; *u; u++) {
            unsigned char ch = *u;
            switch (ch) {
                case '"':  sbuf_putn(s, "\\\"", 2); break;
                case '\\': sbuf_putn(s, "\\\\", 2); break;
                case '\b': sbuf_putn(s, "\\b", 2); break;
                case '\f': sbuf_putn(s, "\\f", 2); break;
                case '\n': sbuf_putn(s, "\\n", 2); break;
                case '\r': sbuf_putn(s, "\\r", 2); break;
                case '\t': sbuf_putn(s, "\\t", 2); break;
                default:
                    if (ch < 0x20) {
                        char esc[7];
                        snprintf(esc, sizeof esc, "\\u%04x", ch);
                        sbuf_putn(s, esc, 6);
                    } else {
                        /* bytes >= 0x20, including UTF-8, pass through */
                        sbuf_putc(s, (char)ch);
                    }
            }
        }
    }
    sbuf_putc(s, '"');
}

/* --------------------------------------------------------------------------
 * JSON object builder (thin wrapper over sbuf that tracks field separators).
 * ------------------------------------------------------------------------ */
struct jobj {
    struct sbuf s;
    int n;
};

static void jobj_begin(struct jobj *o) {
    sbuf_init(&o->s);
    o->n = 0;
    sbuf_putc(&o->s, '{');
}

static void jobj_key(struct jobj *o, const char *key) {
    if (o->n++) sbuf_putc(&o->s, ',');
    sbuf_put_json_string(&o->s, key);
    sbuf_putc(&o->s, ':');
}

static void jobj_str(struct jobj *o, const char *key, const char *val) {
    jobj_key(o, key);
    sbuf_put_json_string(&o->s, val);
}

static void jobj_long(struct jobj *o, const char *key, long val) {
    jobj_key(o, key);
    sbuf_putlong(&o->s, val);
}

static void jobj_double(struct jobj *o, const char *key, double val) {
    jobj_key(o, key);
    sbuf_putdouble(&o->s, val);
}

static void jobj_bool(struct jobj *o, const char *key, int val) {
    jobj_key(o, key);
    sbuf_puts(&o->s, val ? "true" : "false");
}

/* Append a pre-formatted raw JSON value (e.g. caller-supplied metadata). */
static void jobj_raw(struct jobj *o, const char *key, const char *raw_json) {
    jobj_key(o, key);
    sbuf_puts(&o->s, raw_json);
}

/* Close the object and return a heap string (caller frees). NULL on OOM. */
static char *jobj_finish(struct jobj *o) {
    sbuf_putc(&o->s, '}');
    if (o->s.err) {
        free(o->s.data);
        return NULL;
    }
    return o->s.data;
}

/* --------------------------------------------------------------------------
 * Response body accumulator (libcurl write callback).
 * ------------------------------------------------------------------------ */
struct membuf {
    char *data;
    size_t len;
    size_t cap;
    int oom;
};

static size_t write_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
    struct membuf *m = (struct membuf *)userdata;
    size_t add = size * nmemb;
    if (nmemb != 0 && add / nmemb != size) { m->oom = 1; return 0; } /* overflow */
    if (add > SIZE_MAX - 1 || m->len > SIZE_MAX - 1 - add) { /* len+add+1 wrap */
        m->oom = 1;
        return 0;
    }
    if (m->len + add + 1 > m->cap) {
        size_t ncap = m->cap ? m->cap : 256;
        while (ncap < m->len + add + 1) {
            size_t doubled = ncap * 2;
            if (doubled < ncap) { m->oom = 1; return 0; }
            ncap = doubled;
        }
        char *nd = realloc(m->data, ncap);
        if (!nd) { m->oom = 1; return 0; }
        m->data = nd;
        m->cap = ncap;
    }
    memcpy(m->data + m->len, ptr, add);
    m->len += add;
    m->data[m->len] = '\0';
    return add;
}

/* --------------------------------------------------------------------------
 * Client + core request.
 * ------------------------------------------------------------------------ */
struct fiducia_client {
    char *base;      /* base URL with trailing slashes trimmed */
    long timeout_ms; /* <= 0 means no timeout */
};

static int g_curl_inited = 0;

static void ensure_global_init(void) {
    if (!g_curl_inited) {
        curl_global_init(CURL_GLOBAL_DEFAULT);
        g_curl_inited = 1;
    }
}

const char *fiducia_version(void) { return FIDUCIA_VERSION; }

fiducia_client *fiducia_client_new(const char *base_url) {
    if (!base_url) return NULL;
    ensure_global_init();

    fiducia_client *c = (fiducia_client *)calloc(1, sizeof *c);
    if (!c) return NULL;

    size_t n = strlen(base_url);
    while (n > 0 && base_url[n - 1] == '/') n--;
    c->base = (char *)malloc(n + 1);
    if (!c->base) {
        free(c);
        return NULL;
    }
    memcpy(c->base, base_url, n);
    c->base[n] = '\0';
    c->timeout_ms = FIDUCIA_DEFAULT_TIMEOUT_MS;
    return c;
}

void fiducia_client_free(fiducia_client *c) {
    if (!c) return;
    free(c->base);
    free(c);
}

void fiducia_client_set_timeout_ms(fiducia_client *c, long timeout_ms) {
    if (c) c->timeout_ms = timeout_ms;
}

void fiducia_response_free(fiducia_response *out) {
    if (!out) return;
    free(out->body);
    out->body = NULL;
    out->status = 0;
}

/*
 * Reset *out to {0, NULL} and report a bad argument. Every negative return must
 * leave *out zeroed so a caller's fiducia_response_free(out) is always safe,
 * even when out was never initialized (the documented contract).
 */
static int fail_arg(fiducia_response *out) {
    if (out) {
        out->status = 0;
        out->body = NULL;
    }
    return FIDUCIA_ERR_ARG;
}

static int fiducia_request(fiducia_client *c, const char *method,
                           const char *path, const char *body,
                           fiducia_response *out) {
    if (!c || !method || !path || !out) return fail_arg(out);
    out->status = 0;
    out->body = NULL;

    CURL *h = curl_easy_init();
    if (!h) return FIDUCIA_ERR_TRANSPORT;

    struct membuf m = {NULL, 0, 0, 0};
    struct curl_slist *hdrs = NULL;
    struct sbuf url;
    int rc = FIDUCIA_OK;

    sbuf_init(&url);
    sbuf_puts(&url, c->base);
    sbuf_puts(&url, path);
    if (url.err) {
        rc = FIDUCIA_ERR_MEMORY;
        goto done;
    }

    curl_easy_setopt(h, CURLOPT_URL, url.data);
    curl_easy_setopt(h, CURLOPT_CUSTOMREQUEST, method);
    curl_easy_setopt(h, CURLOPT_WRITEFUNCTION, write_cb);
    curl_easy_setopt(h, CURLOPT_WRITEDATA, &m);
    curl_easy_setopt(h, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(h, CURLOPT_FOLLOWLOCATION, 0L);
    if (c->timeout_ms > 0) {
        curl_easy_setopt(h, CURLOPT_TIMEOUT_MS, c->timeout_ms);
    }
    if (body) {
        hdrs = curl_slist_append(hdrs, "Content-Type: application/json");
        if (!hdrs) {
            rc = FIDUCIA_ERR_MEMORY;
            goto done;
        }
        curl_easy_setopt(h, CURLOPT_HTTPHEADER, hdrs);
        curl_easy_setopt(h, CURLOPT_POSTFIELDS, body);
        curl_easy_setopt(h, CURLOPT_POSTFIELDSIZE, (long)strlen(body));
    }

    CURLcode res = curl_easy_perform(h);
    if (res != CURLE_OK) {
        rc = m.oom ? FIDUCIA_ERR_MEMORY : FIDUCIA_ERR_TRANSPORT;
        free(m.data);
        goto done;
    }

    long code = 0;
    curl_easy_getinfo(h, CURLINFO_RESPONSE_CODE, &code);
    out->status = code;
    if (m.len > 0) {
        out->body = m.data; /* transfer ownership */
        m.data = NULL;
    } else {
        free(m.data);
        out->body = NULL;
    }

done:
    curl_slist_free_all(hdrs);
    free(url.data);
    curl_easy_cleanup(h);
    return rc;
}

/*
 * Finalize a built request and send it. Takes ownership of `path->data` and of
 * `body` (both freed here). When `body_expected` is set, a NULL `body` is
 * treated as an out-of-memory failure from the JSON builder.
 */
static int send_req(fiducia_client *c, const char *method, struct sbuf *path,
                    char *body, int body_expected, fiducia_response *out) {
    int rc;
    if (out) {
        /* Honor the negative-return contract on the OOM paths below, where we
         * never reach fiducia_request (which does its own reset). */
        out->status = 0;
        out->body = NULL;
    }
    if (!out) {
        rc = FIDUCIA_ERR_ARG;
    } else if (path->err || (body_expected && body == NULL)) {
        rc = FIDUCIA_ERR_MEMORY;
    } else {
        rc = fiducia_request(c, method, path->data, body, out);
    }
    free(path->data);
    free(body);
    return rc;
}

/* Percent-encode `s` into `dst`. Returns 0 on success, -1 on failure. */
static int append_escaped(struct sbuf *dst, const char *s) {
    char *e = curl_easy_escape(NULL, s ? s : "", 0);
    if (!e) return -1;
    sbuf_puts(dst, e);
    curl_free(e);
    return 0;
}

/* --------------------------------------------------------------------------
 * misc
 * ------------------------------------------------------------------------ */
int fiducia_health(fiducia_client *c, fiducia_response *out) {
    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/healthz");
    return send_req(c, "GET", &p, NULL, 0, out);
}

int fiducia_status(fiducia_client *c, fiducia_response *out) {
    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/v1/status");
    return send_req(c, "GET", &p, NULL, 0, out);
}

/* --------------------------------------------------------------------------
 * locks
 * ------------------------------------------------------------------------ */
int fiducia_lock_get(fiducia_client *c, const char *key, fiducia_response *out) {
    if (!c || !key) return fail_arg(out);
    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/v1/locks?key=");
    if (append_escaped(&p, key) != 0) p.err = 1;
    return send_req(c, "GET", &p, NULL, 0, out);
}

int fiducia_lock_acquire(fiducia_client *c, const char *key, const char *holder,
                         long ttl_ms, int wait, fiducia_response *out) {
    if (!c || !key) return fail_arg(out);
    struct jobj o;
    jobj_begin(&o);
    jobj_str(&o, "key", key);
    if (holder) jobj_str(&o, "holder", holder);
    if (ttl_ms > 0) jobj_long(&o, "ttl_ms", ttl_ms);
    jobj_bool(&o, "wait", wait ? 1 : 0);
    char *body = jobj_finish(&o);

    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/v1/locks/acquire");
    return send_req(c, "POST", &p, body, 1, out);
}

int fiducia_lock_acquire_many(fiducia_client *c, const char *const *keys,
                              size_t n_keys, const char *holder, long ttl_ms,
                              int wait, fiducia_response *out) {
    if (!c || (!keys && n_keys > 0)) return fail_arg(out);

    /* Build the keys array as a raw JSON value. */
    struct sbuf arr;
    sbuf_init(&arr);
    sbuf_putc(&arr, '[');
    for (size_t i = 0; i < n_keys; i++) {
        if (i) sbuf_putc(&arr, ',');
        sbuf_put_json_string(&arr, keys[i]);
    }
    sbuf_putc(&arr, ']');

    struct jobj o;
    jobj_begin(&o);
    if (arr.err) o.s.err = 1;
    jobj_raw(&o, "keys", arr.data ? arr.data : "[]");
    if (holder) jobj_str(&o, "holder", holder);
    if (ttl_ms > 0) jobj_long(&o, "ttl_ms", ttl_ms);
    jobj_bool(&o, "wait", wait ? 1 : 0);
    char *body = jobj_finish(&o);
    free(arr.data);

    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/v1/locks/acquire");
    return send_req(c, "POST", &p, body, 1, out);
}

int fiducia_try_lock(fiducia_client *c, const char *key, const char *holder,
                     long ttl_ms, fiducia_response *out) {
    return fiducia_lock_acquire(c, key, holder, ttl_ms, 0, out);
}

int fiducia_must_lock(fiducia_client *c, const char *key, const char *holder,
                      long ttl_ms, fiducia_response *out) {
    return fiducia_lock_acquire(c, key, holder, ttl_ms, 1, out);
}

int fiducia_lock(fiducia_client *c, const char *key, const char *holder,
                 long ttl_ms, fiducia_response *out) {
    return fiducia_must_lock(c, key, holder, ttl_ms, out);
}

int fiducia_lock_release(fiducia_client *c, const char *key, const char *holder,
                         long fencing_token, fiducia_response *out) {
    if (!c || !holder) return fail_arg(out);
    (void)key; /* accepted for symmetry; not sent in the body */
    struct jobj o;
    jobj_begin(&o);
    jobj_str(&o, "holder", holder);
    jobj_long(&o, "fencing_token", fencing_token);
    char *body = jobj_finish(&o);

    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/v1/locks/release");
    return send_req(c, "POST", &p, body, 1, out);
}

/* --------------------------------------------------------------------------
 * semaphores
 * ------------------------------------------------------------------------ */
int fiducia_semaphore_get(fiducia_client *c, const char *key,
                          fiducia_response *out) {
    if (!c || !key) return fail_arg(out);
    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/v1/semaphores?key=");
    if (append_escaped(&p, key) != 0) p.err = 1;
    return send_req(c, "GET", &p, NULL, 0, out);
}

int fiducia_semaphore_acquire(fiducia_client *c, const char *key, long limit,
                              const char *holder, long ttl_ms, int wait,
                              fiducia_response *out) {
    if (!c || !key) return fail_arg(out);
    struct jobj o;
    jobj_begin(&o);
    jobj_str(&o, "key", key);
    if (holder) jobj_str(&o, "holder", holder);
    if (ttl_ms > 0) jobj_long(&o, "ttl_ms", ttl_ms);
    jobj_long(&o, "limit", limit);
    jobj_bool(&o, "wait", wait ? 1 : 0);
    char *body = jobj_finish(&o);

    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/v1/semaphores/acquire");
    return send_req(c, "POST", &p, body, 1, out);
}

int fiducia_try_semaphore(fiducia_client *c, const char *key, long limit,
                          const char *holder, long ttl_ms,
                          fiducia_response *out) {
    return fiducia_semaphore_acquire(c, key, limit, holder, ttl_ms, 0, out);
}

int fiducia_must_semaphore(fiducia_client *c, const char *key, long limit,
                           const char *holder, long ttl_ms,
                           fiducia_response *out) {
    return fiducia_semaphore_acquire(c, key, limit, holder, ttl_ms, 1, out);
}

int fiducia_semaphore(fiducia_client *c, const char *key, long limit,
                      const char *holder, long ttl_ms, fiducia_response *out) {
    return fiducia_must_semaphore(c, key, limit, holder, ttl_ms, out);
}

int fiducia_semaphore_release(fiducia_client *c, const char *key,
                              const char *holder, long fencing_token,
                              fiducia_response *out) {
    if (!c || !key || !holder) return fail_arg(out);
    struct jobj o;
    jobj_begin(&o);
    jobj_str(&o, "key", key);
    jobj_str(&o, "holder", holder);
    jobj_long(&o, "fencing_token", fencing_token);
    char *body = jobj_finish(&o);

    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/v1/semaphores/release");
    return send_req(c, "POST", &p, body, 1, out);
}

/* --------------------------------------------------------------------------
 * idempotency keys
 * ------------------------------------------------------------------------ */
int fiducia_idempotency_get(fiducia_client *c, const char *key,
                            fiducia_response *out) {
    if (!c || !key) return fail_arg(out);
    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/v1/idempotency?key=");
    if (append_escaped(&p, key) != 0) p.err = 1;
    return send_req(c, "GET", &p, NULL, 0, out);
}

int fiducia_idempotency_claim(fiducia_client *c, const char *key,
                              const char *owner, long ttl_ms, const char *ttl,
                              const char *metadata_json, fiducia_response *out) {
    if (!c || !key) return fail_arg(out);
    struct jobj o;
    jobj_begin(&o);
    jobj_str(&o, "key", key);
    if (owner) jobj_str(&o, "owner", owner);
    if (ttl_ms > 0) jobj_long(&o, "ttl_ms", ttl_ms);
    if (ttl) jobj_str(&o, "ttl", ttl);
    if (metadata_json) jobj_raw(&o, "metadata", metadata_json);
    char *body = jobj_finish(&o);

    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/v1/idempotency/claim");
    return send_req(c, "POST", &p, body, 1, out);
}

int fiducia_idempotency_complete(fiducia_client *c, const char *key,
                                 const char *owner, long fencing_token,
                                 const char *result_json,
                                 fiducia_response *out) {
    if (!c || !key || !owner) return fail_arg(out);
    struct jobj o;
    jobj_begin(&o);
    jobj_str(&o, "key", key);
    jobj_str(&o, "owner", owner);
    jobj_long(&o, "fencing_token", fencing_token);
    if (result_json) jobj_raw(&o, "result", result_json);
    char *body = jobj_finish(&o);

    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/v1/idempotency/complete");
    return send_req(c, "POST", &p, body, 1, out);
}

/* --------------------------------------------------------------------------
 * reader-writer locks
 * ------------------------------------------------------------------------ */
static int rw_acquire(fiducia_client *c, const char *key, const char *verb,
                      long ttl_ms, int wait, fiducia_response *out) {
    if (!c || !key) return fail_arg(out);
    struct jobj o;
    jobj_begin(&o);
    if (ttl_ms > 0) jobj_long(&o, "ttl_ms", ttl_ms);
    jobj_bool(&o, "wait", wait ? 1 : 0);
    char *body = jobj_finish(&o);

    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/v1/rw/");
    if (append_escaped(&p, key) != 0) p.err = 1;
    sbuf_putc(&p, '/');
    sbuf_puts(&p, verb);
    return send_req(c, "POST", &p, body, 1, out);
}

static int rw_end(fiducia_client *c, const char *key, const char *verb,
                  const char *lock_id, fiducia_response *out) {
    if (!c || !key || !lock_id) return fail_arg(out);
    struct jobj o;
    jobj_begin(&o);
    jobj_str(&o, "lock_id", lock_id);
    char *body = jobj_finish(&o);

    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/v1/rw/");
    if (append_escaped(&p, key) != 0) p.err = 1;
    sbuf_putc(&p, '/');
    sbuf_puts(&p, verb);
    sbuf_puts(&p, "/end");
    return send_req(c, "POST", &p, body, 1, out);
}

int fiducia_rw_acquire_read(fiducia_client *c, const char *key, long ttl_ms,
                            int wait, fiducia_response *out) {
    return rw_acquire(c, key, "read", ttl_ms, wait, out);
}

int fiducia_rw_end_read(fiducia_client *c, const char *key, const char *lock_id,
                        fiducia_response *out) {
    return rw_end(c, key, "read", lock_id, out);
}

int fiducia_rw_acquire_write(fiducia_client *c, const char *key, long ttl_ms,
                             int wait, fiducia_response *out) {
    return rw_acquire(c, key, "write", ttl_ms, wait, out);
}

int fiducia_rw_end_write(fiducia_client *c, const char *key, const char *lock_id,
                         fiducia_response *out) {
    return rw_end(c, key, "write", lock_id, out);
}

/* --------------------------------------------------------------------------
 * config KV
 * ------------------------------------------------------------------------ */
int fiducia_kv_get(fiducia_client *c, const char *key, fiducia_response *out) {
    if (!c || !key) return fail_arg(out);
    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/v1/kv?key=");
    if (append_escaped(&p, key) != 0) p.err = 1;
    return send_req(c, "GET", &p, NULL, 0, out);
}

int fiducia_kv_put(fiducia_client *c, const char *key, const char *value,
                   long ttl_ms, long prev_revision, fiducia_response *out) {
    if (!c || !key || !value) return fail_arg(out);
    struct jobj o;
    jobj_begin(&o);
    jobj_str(&o, "value", value);
    if (ttl_ms > 0) jobj_long(&o, "ttl_ms", ttl_ms);
    if (prev_revision >= 0) jobj_long(&o, "prev_revision", prev_revision);
    char *body = jobj_finish(&o);

    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/v1/kv?key=");
    if (append_escaped(&p, key) != 0) p.err = 1;
    return send_req(c, "PUT", &p, body, 1, out);
}

int fiducia_kv_delete(fiducia_client *c, const char *key,
                      fiducia_response *out) {
    if (!c || !key) return fail_arg(out);
    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/v1/kv?key=");
    if (append_escaped(&p, key) != 0) p.err = 1;
    return send_req(c, "DELETE", &p, NULL, 0, out);
}

int fiducia_kv_list(fiducia_client *c, const char *prefix,
                    fiducia_response *out) {
    if (!c || !prefix) return fail_arg(out);
    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/v1/kv?prefix=");
    if (append_escaped(&p, prefix) != 0) p.err = 1;
    return send_req(c, "GET", &p, NULL, 0, out);
}

/* --------------------------------------------------------------------------
 * rate limiting
 * ------------------------------------------------------------------------ */
int fiducia_rate_limit_get(fiducia_client *c, const char *tenant,
                           const char *key, fiducia_response *out) {
    if (!c || !tenant || !key) return fail_arg(out);
    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/v1/rate-limit/");
    if (append_escaped(&p, tenant) != 0) p.err = 1;
    sbuf_putc(&p, '/');
    if (append_escaped(&p, key) != 0) p.err = 1;
    return send_req(c, "GET", &p, NULL, 0, out);
}

int fiducia_rate_limit_check(fiducia_client *c, const char *tenant,
                             const char *key, const char *algorithm, long limit,
                             long window_ms, double refill_per_second, long cost,
                             fiducia_response *out) {
    if (!c || !tenant || !key || !algorithm) return fail_arg(out);
    struct jobj o;
    jobj_begin(&o);
    jobj_str(&o, "algorithm", algorithm);
    jobj_long(&o, "limit", limit);
    jobj_long(&o, "window_ms", window_ms);
    if (refill_per_second >= 0) jobj_double(&o, "refill_per_second", refill_per_second);
    if (cost >= 0) jobj_long(&o, "cost", cost);
    char *body = jobj_finish(&o);

    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/v1/rate-limit/");
    if (append_escaped(&p, tenant) != 0) p.err = 1;
    sbuf_putc(&p, '/');
    if (append_escaped(&p, key) != 0) p.err = 1;
    sbuf_puts(&p, "/check");
    return send_req(c, "POST", &p, body, 1, out);
}

/* --------------------------------------------------------------------------
 * cron & scheduling
 * ------------------------------------------------------------------------ */
int fiducia_schedule_get(fiducia_client *c, const char *name,
                         fiducia_response *out) {
    if (!c || !name) return fail_arg(out);
    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/v1/cron/schedules/");
    if (append_escaped(&p, name) != 0) p.err = 1;
    return send_req(c, "GET", &p, NULL, 0, out);
}

int fiducia_schedule_upsert(fiducia_client *c, const char *name,
                            const char *target_json, const char *cron,
                            long one_shot_at_ms, const char *delivery,
                            long max_retries, fiducia_response *out) {
    if (!c || !name || !target_json) return fail_arg(out);
    struct jobj o;
    jobj_begin(&o);
    jobj_raw(&o, "target", target_json);
    if (cron) jobj_str(&o, "cron", cron);
    if (one_shot_at_ms >= 0) jobj_long(&o, "one_shot_at_ms", one_shot_at_ms);
    if (delivery) jobj_str(&o, "delivery", delivery);
    if (max_retries >= 0) jobj_long(&o, "max_retries", max_retries);
    char *body = jobj_finish(&o);

    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/v1/cron/schedules/");
    if (append_escaped(&p, name) != 0) p.err = 1;
    return send_req(c, "PUT", &p, body, 1, out);
}

int fiducia_schedule_record_run(fiducia_client *c, const char *name,
                                const char *fire_id, long fired_at_ms,
                                fiducia_response *out) {
    if (!c || !name || !fire_id) return fail_arg(out);
    struct jobj o;
    jobj_begin(&o);
    jobj_str(&o, "fire_id", fire_id);
    if (fired_at_ms >= 0) jobj_long(&o, "fired_at_ms", fired_at_ms);
    char *body = jobj_finish(&o);

    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/v1/cron/schedules/");
    if (append_escaped(&p, name) != 0) p.err = 1;
    sbuf_puts(&p, "/runs");
    return send_req(c, "POST", &p, body, 1, out);
}

int fiducia_schedule_history(fiducia_client *c, const char *name,
                             fiducia_response *out) {
    if (!c || !name) return fail_arg(out);
    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/v1/cron/schedules/");
    if (append_escaped(&p, name) != 0) p.err = 1;
    sbuf_puts(&p, "/history");
    return send_req(c, "GET", &p, NULL, 0, out);
}

/* --------------------------------------------------------------------------
 * leader election
 * ------------------------------------------------------------------------ */
int fiducia_election_get(fiducia_client *c, const char *name,
                         fiducia_response *out) {
    if (!c || !name) return fail_arg(out);
    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/v1/elections/");
    if (append_escaped(&p, name) != 0) p.err = 1;
    return send_req(c, "GET", &p, NULL, 0, out);
}

int fiducia_election_campaign(fiducia_client *c, const char *name,
                              const char *candidate, long ttl_ms,
                              const char *metadata_json, fiducia_response *out) {
    if (!c || !name || !candidate) return fail_arg(out);
    struct jobj o;
    jobj_begin(&o);
    jobj_str(&o, "candidate", candidate);
    jobj_long(&o, "ttl_ms", ttl_ms);
    if (metadata_json) jobj_raw(&o, "metadata", metadata_json);
    char *body = jobj_finish(&o);

    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/v1/elections/");
    if (append_escaped(&p, name) != 0) p.err = 1;
    sbuf_puts(&p, "/campaign");
    return send_req(c, "POST", &p, body, 1, out);
}

int fiducia_election_renew(fiducia_client *c, const char *name,
                           const char *candidate, long fencing_token,
                           fiducia_response *out) {
    if (!c || !name || !candidate) return fail_arg(out);
    struct jobj o;
    jobj_begin(&o);
    jobj_str(&o, "candidate", candidate);
    jobj_long(&o, "fencing_token", fencing_token);
    char *body = jobj_finish(&o);

    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/v1/elections/");
    if (append_escaped(&p, name) != 0) p.err = 1;
    sbuf_puts(&p, "/renew");
    return send_req(c, "POST", &p, body, 1, out);
}

int fiducia_election_resign(fiducia_client *c, const char *name,
                            const char *candidate, long fencing_token,
                            fiducia_response *out) {
    if (!c || !name || !candidate) return fail_arg(out);
    struct jobj o;
    jobj_begin(&o);
    jobj_str(&o, "candidate", candidate);
    jobj_long(&o, "fencing_token", fencing_token);
    char *body = jobj_finish(&o);

    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/v1/elections/");
    if (append_escaped(&p, name) != 0) p.err = 1;
    sbuf_puts(&p, "/resign");
    return send_req(c, "POST", &p, body, 1, out);
}

/* --------------------------------------------------------------------------
 * service discovery
 * ------------------------------------------------------------------------ */
int fiducia_service_instances(fiducia_client *c, const char *service,
                              fiducia_response *out) {
    if (!c || !service) return fail_arg(out);
    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/v1/services/");
    if (append_escaped(&p, service) != 0) p.err = 1;
    return send_req(c, "GET", &p, NULL, 0, out);
}

int fiducia_service_register(fiducia_client *c, const char *service,
                             const char *instance_id, const char *address,
                             long ttl_ms, const char *metadata_json,
                             fiducia_response *out) {
    if (!c || !service || !instance_id || !address) return fail_arg(out);
    struct jobj o;
    jobj_begin(&o);
    jobj_str(&o, "address", address);
    jobj_long(&o, "ttl_ms", ttl_ms);
    if (metadata_json) jobj_raw(&o, "metadata", metadata_json);
    char *body = jobj_finish(&o);

    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/v1/services/");
    if (append_escaped(&p, service) != 0) p.err = 1;
    sbuf_puts(&p, "/instances/");
    if (append_escaped(&p, instance_id) != 0) p.err = 1;
    return send_req(c, "PUT", &p, body, 1, out);
}

int fiducia_service_heartbeat(fiducia_client *c, const char *service,
                              const char *instance_id, long ttl_ms,
                              fiducia_response *out) {
    if (!c || !service || !instance_id) return fail_arg(out);
    struct jobj o;
    jobj_begin(&o);
    if (ttl_ms > 0) jobj_long(&o, "ttl_ms", ttl_ms);
    char *body = jobj_finish(&o);

    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/v1/services/");
    if (append_escaped(&p, service) != 0) p.err = 1;
    sbuf_puts(&p, "/instances/");
    if (append_escaped(&p, instance_id) != 0) p.err = 1;
    sbuf_puts(&p, "/heartbeat");
    return send_req(c, "POST", &p, body, 1, out);
}

int fiducia_service_deregister(fiducia_client *c, const char *service,
                               const char *instance_id, fiducia_response *out) {
    if (!c || !service || !instance_id) return fail_arg(out);
    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/v1/services/");
    if (append_escaped(&p, service) != 0) p.err = 1;
    sbuf_puts(&p, "/instances/");
    if (append_escaped(&p, instance_id) != 0) p.err = 1;
    return send_req(c, "DELETE", &p, NULL, 0, out);
}

int fiducia_service_list(fiducia_client *c, fiducia_response *out) {
    struct sbuf p;
    sbuf_init(&p);
    sbuf_puts(&p, "/v1/services");
    return send_req(c, "GET", &p, NULL, 0, out);
}
