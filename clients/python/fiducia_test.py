"""Offline unit tests for the generated Python client + cli.py — no cluster
needed. A RecordingClient captures the (method, path, body) each SDK call would
send, so we assert the exact wire mapping; a fake client verifies cli.py dispatch.

Run: python3 -m unittest fiducia_test   (from clients/python/)
"""
import contextlib
import io
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cli  # noqa: E402
import fiducia  # noqa: E402


class RecordingClient(fiducia.FiduciaClient):
    def __init__(self):
        super().__init__("https://fiducia.test")
        self.calls = []

    def _request(self, method, path, body=None):
        self.calls.append((method, path, body))
        return {"method": method, "path": path, "body": body}


# Each case: (callable, expected method, expected path, expected body).
# Bodies include every body field (None when unset) — the generated client sends
# them so the server's Option<T> fields default. dict equality ignores key order.
ROUTES = [
    (lambda c: c.health(), "GET", "/healthz", None),
    (lambda c: c.status(), "GET", "/v1/status", None),

    (lambda c: c.lock_get("orders/42"), "GET", "/v1/locks?key=orders%2F42", None),
    (lambda c: c.lock_acquire("orders/42", holder="w", ttl_ms=30000, wait=True),
     "POST", "/v1/locks/acquire", {"key": "orders/42", "holder": "w", "ttl_ms": 30000, "wait": True}),
    (lambda c: c.lock_acquire_many(["a", "b"], holder="w"),
     "POST", "/v1/locks/acquire", {"keys": ["a", "b"], "holder": "w", "ttl_ms": None, "wait": None}),
    (lambda c: c.lock_release("w", 11), "POST", "/v1/locks/release", {"holder": "w", "fencing_token": 11}),

    (lambda c: c.semaphore_get("pools/db"), "GET", "/v1/semaphores?key=pools%2Fdb", None),
    (lambda c: c.semaphore_acquire("pools/db", 3, holder="w", ttl_ms=20000, wait=True),
     "POST", "/v1/semaphores/acquire", {"key": "pools/db", "limit": 3, "holder": "w", "ttl_ms": 20000, "wait": True}),
    (lambda c: c.semaphore_release("pools/db", "w", 12),
     "POST", "/v1/semaphores/release", {"key": "pools/db", "holder": "w", "fencing_token": 12}),

    (lambda c: c.kv_get("flags/x"), "GET", "/v1/kv?key=flags%2Fx", None),
    (lambda c: c.kv_put("flags/x", "on", ttl_ms=60000, prev_revision=7),
     "PUT", "/v1/kv?key=flags%2Fx", {"value": "on", "ttl_ms": 60000, "prev_revision": 7}),
    (lambda c: c.kv_delete("flags/x"), "DELETE", "/v1/kv?key=flags%2Fx", None),

    (lambda c: c.election_get("e"), "GET", "/v1/elections/e", None),
    (lambda c: c.election_campaign("e", "node-a", 15000),
     "POST", "/v1/elections/e/campaign", {"candidate": "node-a", "ttl_ms": 15000}),
    (lambda c: c.election_renew("e", "node-a", 21),
     "POST", "/v1/elections/e/renew", {"candidate": "node-a", "fencing_token": 21}),
    (lambda c: c.election_resign("e", "node-a", 21),
     "POST", "/v1/elections/e/resign", {"candidate": "node-a", "fencing_token": 21}),

    (lambda c: c.service_instances("api"), "GET", "/v1/services/api", None),
    (lambda c: c.service_register("api", "i-1", "10.0.0.1:9000", 10000, metadata={"az": "a"}),
     "PUT", "/v1/services/api/instances/i-1", {"address": "10.0.0.1:9000", "ttl_ms": 10000, "metadata": {"az": "a"}}),
    (lambda c: c.service_heartbeat("api", "i-1", ttl_ms=20000),
     "POST", "/v1/services/api/instances/i-1/heartbeat", {"ttl_ms": 20000}),
    (lambda c: c.service_deregister("api", "i-1"), "DELETE", "/v1/services/api/instances/i-1", None),

    (lambda c: c.rate_limit_get("t", "c"), "GET", "/v1/rate-limit/t/c", None),
    (lambda c: c.rate_limit_check("t/a", "checkout", "token_bucket", 100, 60000, cost=2),
     "POST", "/v1/rate-limit/t%2Fa/checkout/check",
     {"algorithm": "token_bucket", "limit": 100, "window_ms": 60000, "refill_per_second": None, "cost": 2}),

    (lambda c: c.schedule_get("nightly"), "GET", "/v1/cron/schedules/nightly", None),
    (lambda c: c.schedule_upsert("nightly", {"kind": "webhook", "url": "https://x/y"}, cron="0 0 * * *",
                                 delivery="exactly_once", max_retries=5),
     "PUT", "/v1/cron/schedules/nightly",
     {"target": {"kind": "webhook", "url": "https://x/y"}, "cron": "0 0 * * *", "one_shot_at_ms": None,
      "delivery": "exactly_once", "max_retries": 5}),
    (lambda c: c.schedule_record_run("nightly", "fire-1", fired_at_ms=123),
     "POST", "/v1/cron/schedules/nightly/runs", {"fire_id": "fire-1", "fired_at_ms": 123}),
    (lambda c: c.schedule_history("nightly"), "GET", "/v1/cron/schedules/nightly/history", None),
]


class CliFake:
    """A stand-in client that records the SDK call cli.py dispatches to."""
    def __init__(self):
        self.calls = []

    def factory(self, base_url, timeout=30):
        return self

    def __getattr__(self, name):
        def call(*args, **kwargs):
            self.calls.append((name, args, kwargs))
            return {"ok": name}
        return call


CLI = [
    (["status"], ("status", (), {})),
    (["lock", "acquire", "--keys", "a,b", "--holder", "h", "--ttl-ms", "100", "--wait"],
     ("lock_acquire_many", (["a", "b"],), {"holder": "h", "ttl_ms": 100, "wait": True})),
    (["lock", "release", "--holder", "h", "--token", "7"], ("lock_release", ("h", 7), {})),
    (["sem", "acquire", "--key", "pool", "--limit", "4", "--holder", "h"],
     ("semaphore_acquire", ("pool", 4), {"holder": "h", "ttl_ms": None, "wait": False})),
    (["kv", "put", "--key", "flags/x", "--value", "on", "--prev-revision", "3"],
     ("kv_put", ("flags/x", "on"), {"ttl_ms": None, "prev_revision": 3})),
    (["election", "campaign", "--name", "e", "--candidate", "node-a", "--ttl-ms", "15000"],
     ("election_campaign", ("e", "node-a", 15000), {})),
    (["service", "register", "--service", "api", "--id", "i-1", "--address", "10.0.0.1:9000",
      "--ttl-ms", "10000", "--meta", "az=a"],
     ("service_register", ("api", "i-1", "10.0.0.1:9000", 10000), {"metadata": {"az": "a"}})),
    (["ratelimit", "check", "--tenant", "t", "--key", "c", "--algorithm", "sliding_window",
      "--limit", "5", "--window-ms", "1000"],
     ("rate_limit_check", ("t", "c", "sliding_window", 5, 1000), {"refill_per_second": None, "cost": None})),
    (["cron", "upsert", "--name", "nightly", "--cron", "0 0 * * *", "--webhook", "https://x/y"],
     ("schedule_upsert", ("nightly", {"kind": "webhook", "url": "https://x/y"}),
      {"cron": "0 0 * * *", "one_shot_at_ms": None, "delivery": None, "max_retries": None})),
]


class GeneratedClientTests(unittest.TestCase):
    def test_routes(self):
        for fn, method, path, body in ROUTES:
            c = RecordingClient()
            fn(c)
            with self.subTest(path=path):
                self.assertEqual(c.calls[-1], (method, path, body))

    def test_cli_dispatch(self):
        for argv, expected in CLI:
            fake = CliFake()
            with self.subTest(argv=argv), contextlib.redirect_stdout(io.StringIO()):
                rc = cli.main(argv, client_factory=fake.factory)
            self.assertEqual(rc, 0)
            self.assertEqual(fake.calls, [expected])


if __name__ == "__main__":
    unittest.main()
