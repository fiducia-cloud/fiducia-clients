"""Fiducia HTTP client (Python). Zero-dependency — stdlib urllib. Implements PROTOCOL.md.

    from fiducia import FiduciaClient
    c = FiduciaClient("https://api.fiducia.cloud")
    lock = c.lock_acquire("orders/checkout", holder="worker-a", ttl_ms=30000)
    c.lock_release("orders/checkout", "worker-a", lock["result"]["fencing_token"])
"""

import json
import os as _os
import sys as _sys
import urllib.error
import urllib.parse
import urllib.request

# Shared, generated payload types (fiducia-interfaces), re-exported as
# `fiducia.types` so callers can build typed payloads from one source of truth.
# In-repo we reach the generated python adapter directly; a packaged install
# would make `fiducia_interfaces` a normal dependency instead.
_sys.path.insert(
    0,
    _os.path.join(
        _os.path.dirname(__file__), "..", "..", "..", "fiducia-interfaces", "generated", "python"
    ),
)
try:
    import fiducia_interfaces as types  # noqa: E402
except ImportError:  # pragma: no cover
    types = None


class FiduciaError(Exception):
    def __init__(self, status, body):
        super().__init__("fiducia: HTTP %s" % status)
        self.status = status
        self.body = body


def _enc(s):
    return urllib.parse.quote(str(s), safe="")


def _query(path, **params):
    qs = urllib.parse.urlencode(
        {key: value for key, value in params.items() if value is not None},
        doseq=True,
    )
    return "%s?%s" % (path, qs) if qs else path


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

    def _watch(self, path):
        req = urllib.request.Request(self.base + path, method="GET")
        req.add_header("accept", "text/event-stream")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                event = {}
                data = []
                for raw_line in r:
                    line = raw_line.decode().rstrip("\r\n")
                    if not line:
                        decoded = _decode_sse_event(event, data)
                        if decoded is not None:
                            yield decoded
                        event, data = {}, []
                        continue
                    if line.startswith(":"):
                        continue
                    field, _, value = line.partition(":")
                    if value.startswith(" "):
                        value = value[1:]
                    if field == "event":
                        event["event"] = value
                    elif field == "id":
                        event["id"] = value
                    elif field == "data":
                        data.append(value)
                decoded = _decode_sse_event(event, data)
                if decoded is not None:
                    yield decoded
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

    def lock_acquire(self, key, holder=None, ttl_ms=None, wait=False, max=None):
        return self._request("POST", "/v1/locks/%s/acquire" % _enc(key),
                             {"holder": holder, "ttl_ms": ttl_ms, "wait": wait, "max": max})

    def lock_acquire_many(self, keys, holder=None, ttl_ms=None, wait=False):
        return self._request("POST", "/v1/locks/acquire-many",
                             {"keys": keys, "holder": holder, "ttl_ms": ttl_ms, "wait": wait})

    def lock_release(self, key, holder, fencing_token):
        return self._request("POST", "/v1/locks/%s/release" % _enc(key),
                             {"holder": holder, "fencing_token": fencing_token})

    def lock_release_many(self, lock_id):
        return self._request("POST", "/v1/locks/release-many", {"lock_id": lock_id})

    # --- semaphores ---
    def semaphore_acquire(self, key, holder=None, ttl_ms=None, max=2, wait=False):
        return self._request("POST", "/v1/semaphores/%s/acquire" % _enc(key),
                             {"holder": holder, "ttl_ms": ttl_ms, "wait": wait, "max": max})

    def semaphore_release(self, key, holder, fencing_token):
        return self._request("POST", "/v1/semaphores/%s/release" % _enc(key),
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
        return self._request("GET", _query("/v1/kv", key=key))

    def kv_put(self, key, value, ttl_ms=None, prev_revision=None):
        return self._request("PUT", _query("/v1/kv", key=key),
                             {"value": value, "ttl_ms": ttl_ms, "prev_revision": prev_revision})

    def kv_delete(self, key):
        return self._request("DELETE", _query("/v1/kv", key=key))

    def kv_list(self, prefix):
        return self._request("GET", _query("/v1/kv", prefix=prefix))

    def kv_watch(self, key):
        return self._watch(_query("/v1/kv", key=key, watch="true"))

    def kv_watch_prefix(self, prefix):
        return self._watch(_query("/v1/kv", prefix=prefix, watch="true"))

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

    def election_watch(self, name):
        return self._watch("/v1/elections/%s/watch" % _enc(name))

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

    def service_watch(self, service):
        return self._watch("/v1/services/%s/watch" % _enc(service))


def _decode_sse_event(event, data):
    if not data:
        return None
    raw = "\n".join(data)
    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError:
        decoded = raw
    out = {"event": event.get("event", "message"), "data": decoded}
    if "id" in event:
        out["id"] = event["id"]
    return out
