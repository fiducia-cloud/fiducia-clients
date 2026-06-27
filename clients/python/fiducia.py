"""Fiducia HTTP client (Python). Zero-dependency — stdlib urllib. Implements PROTOCOL.md.

    from fiducia import FiduciaClient
    c = FiduciaClient("https://api.fiducia.cloud")
    lock = c.lock_acquire("orders/checkout", holder="worker-a", ttl_ms=30000)
    c.lock_release("orders/checkout", "worker-a", lock["result"]["fencing_token"])
"""

import json
import urllib.error
import urllib.parse
import urllib.request


class FiduciaError(Exception):
    def __init__(self, status, body):
        super().__init__("fiducia: HTTP %s" % status)
        self.status = status
        self.body = body


def _enc(s):
    return urllib.parse.quote(str(s), safe="")


class FiduciaClient:
    def __init__(self, base_url, timeout=30):
        self.base = base_url.rstrip("/")
        self.timeout = timeout

    def _request(self, method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method)
        if data is not None:
            req.add_header("content-type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                text = r.read().decode()
                return json.loads(text) if text else None
        except urllib.error.HTTPError as e:
            text = e.read().decode()
            raise FiduciaError(e.code, json.loads(text) if text else None)

    # --- misc ---
    def health(self):
        return self._request("GET", "/healthz")

    def status(self):
        return self._request("GET", "/v1/status")

    # --- locks ---
    def lock_get(self, key):
        return self._request("GET", "/v1/locks/%s" % _enc(key))

    def lock_acquire(self, key, holder=None, ttl_ms=None, wait=False):
        return self._request("POST", "/v1/locks/%s/acquire" % _enc(key),
                             {"holder": holder, "ttl_ms": ttl_ms, "wait": wait})

    def lock_release(self, key, holder, fencing_token):
        return self._request("POST", "/v1/locks/%s/release" % _enc(key),
                             {"holder": holder, "fencing_token": fencing_token})

    # --- reader-writer locks ---
    def rw_acquire_read(self, key, ttl_ms=None, wait=True):
        return self._request("POST", "/v1/rw/%s/read" % _enc(key), {"ttl_ms": ttl_ms, "wait": wait})

    def rw_end_read(self, key, lock_id):
        return self._request("POST", "/v1/rw/%s/read/end" % _enc(key), {"lock_id": lock_id})

    def rw_acquire_write(self, key, ttl_ms=None, wait=True):
        return self._request("POST", "/v1/rw/%s/write" % _enc(key), {"ttl_ms": ttl_ms, "wait": wait})

    def rw_end_write(self, key, lock_id):
        return self._request("POST", "/v1/rw/%s/write/end" % _enc(key), {"lock_id": lock_id})

    # --- config KV ---
    def kv_get(self, key):
        return self._request("GET", "/v1/kv/%s" % _enc(key))

    def kv_put(self, key, value, ttl_ms=None, prev_revision=None):
        return self._request("PUT", "/v1/kv/%s" % _enc(key),
                             {"value": value, "ttl_ms": ttl_ms, "prev_revision": prev_revision})

    def kv_delete(self, key):
        return self._request("DELETE", "/v1/kv/%s" % _enc(key))

    def kv_list(self, prefix):
        return self._request("GET", "/v1/kv?prefix=%s" % _enc(prefix))

    # --- rate limiting ---
    def rate_limit_check(self, tenant, key, algorithm, limit, window_ms,
                         refill_per_second=None, cost=None):
        return self._request("POST", "/v1/rate-limit/%s/%s/check" % (_enc(tenant), _enc(key)),
                             {
                                 "algorithm": algorithm,
                                 "limit": limit,
                                 "window_ms": window_ms,
                                 "refill_per_second": refill_per_second,
                                 "cost": cost,
                             })

    def rate_limit_get(self, tenant, key):
        return self._request("GET", "/v1/rate-limit/%s/%s" % (_enc(tenant), _enc(key)))

    # --- cron / scheduling ---
    def schedule_upsert(self, name, target, cron=None, one_shot_at_ms=None,
                        delivery=None, max_retries=None):
        return self._request("PUT", "/v1/cron/schedules/%s" % _enc(name),
                             {
                                 "cron": cron,
                                 "one_shot_at_ms": one_shot_at_ms,
                                 "target": target,
                                 "delivery": delivery,
                                 "max_retries": max_retries,
                             })

    def schedule_get(self, name):
        return self._request("GET", "/v1/cron/schedules/%s" % _enc(name))

    def schedule_record_run(self, name, fire_id, fired_at_ms=None):
        return self._request("POST", "/v1/cron/schedules/%s/runs" % _enc(name),
                             {"fire_id": fire_id, "fired_at_ms": fired_at_ms})

    def schedule_history(self, name):
        return self._request("GET", "/v1/cron/schedules/%s/history" % _enc(name))

    # --- leader election ---
    def election_campaign(self, name, candidate, ttl_ms):
        return self._request("POST", "/v1/elections/%s/campaign" % _enc(name),
                             {"candidate": candidate, "ttl_ms": ttl_ms})

    def election_renew(self, name, candidate, fencing_token):
        return self._request("POST", "/v1/elections/%s/renew" % _enc(name),
                             {"candidate": candidate, "fencing_token": fencing_token})

    def election_resign(self, name, candidate, fencing_token):
        return self._request("POST", "/v1/elections/%s/resign" % _enc(name),
                             {"candidate": candidate, "fencing_token": fencing_token})

    def election_get(self, name):
        return self._request("GET", "/v1/elections/%s" % _enc(name))

    # --- service discovery ---
    def service_register(self, service, instance_id, address, ttl_ms):
        return self._request("PUT", "/v1/services/%s/instances/%s" % (_enc(service), _enc(instance_id)),
                             {"address": address, "ttl_ms": ttl_ms})

    def service_heartbeat(self, service, instance_id):
        return self._request("POST", "/v1/services/%s/instances/%s/heartbeat" % (_enc(service), _enc(instance_id)))

    def service_deregister(self, service, instance_id):
        return self._request("DELETE", "/v1/services/%s/instances/%s" % (_enc(service), _enc(instance_id)))

    def service_instances(self, service):
        return self._request("GET", "/v1/services/%s" % _enc(service))

    def service_list(self):
        return self._request("GET", "/v1/services")
