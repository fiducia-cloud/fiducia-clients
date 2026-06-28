import contextlib
import io
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))

import fiducia  # noqa: E402


class RecordingClient(fiducia.FiduciaClient):
    def __init__(self, base_url="https://fiducia.test", timeout=30):
        super().__init__(base_url, timeout=timeout)
        self.calls = []

    def _request(self, method, path, body=None):
        self.calls.append((method, path, body))
        return {"method": method, "path": path, "body": body}


class FiduciaPythonClientTests(unittest.TestCase):
    def assert_last_call(self, client, method, path, body=None):
        self.assertEqual(client.calls[-1], (method, path, body))

    def test_sdk_routes_cover_coordination_primitives(self):
        c = RecordingClient()

        c.lock_get("orders/42")
        self.assert_last_call(c, "GET", "/v1/locks?key=orders%2F42")
        c.lock_acquire("orders/42", holder="worker-a", ttl_ms=30_000, wait=True)
        self.assert_last_call(
            c,
            "POST",
            "/v1/locks/acquire",
            {"key": "orders/42", "holder": "worker-a", "ttl_ms": 30_000, "wait": True, "max": None},
        )
        c.lock_acquire_many(["orders/42", "inventory/sku-7"], holder="worker-a")
        self.assert_last_call(
            c,
            "POST",
            "/v1/locks/acquire",
            {"keys": ["orders/42", "inventory/sku-7"], "holder": "worker-a", "ttl_ms": None, "wait": False},
        )
        c.lock_release("orders/42", "worker-a", 11)
        self.assert_last_call(c, "POST", "/v1/locks/release", {"holder": "worker-a", "fencing_token": 11})

        c.semaphore_get("pools/db/primary")
        self.assert_last_call(c, "GET", "/v1/semaphores?key=pools%2Fdb%2Fprimary")
        c.semaphore_acquire("pools/db/primary", holder="worker-b", ttl_ms=20_000, max=3, wait=True)
        self.assert_last_call(
            c,
            "POST",
            "/v1/semaphores/acquire",
            {"key": "pools/db/primary", "holder": "worker-b", "ttl_ms": 20_000, "wait": True, "limit": 3},
        )
        c.semaphore_release("pools/db/primary", "worker-b", 12)
        self.assert_last_call(
            c,
            "POST",
            "/v1/semaphores/release",
            {"key": "pools/db/primary", "holder": "worker-b", "fencing_token": 12},
        )

        c.kv_get("flags/new-ui")
        self.assert_last_call(c, "GET", "/v1/kv?key=flags%2Fnew-ui")
        c.kv_put("flags/new-ui", "on", ttl_ms=60_000, prev_revision=7)
        self.assert_last_call(
            c,
            "PUT",
            "/v1/kv?key=flags%2Fnew-ui",
            {"value": "on", "ttl_ms": 60_000, "prev_revision": 7},
        )
        c.kv_delete("flags/new-ui")
        self.assert_last_call(c, "DELETE", "/v1/kv?key=flags%2Fnew-ui")
        c.kv_list("flags/")
        self.assert_last_call(c, "GET", "/v1/kv?prefix=flags%2F")

        c.rate_limit_check("tenant/a", "checkout", "token_bucket", 100, 60_000, cost=2)
        self.assert_last_call(
            c,
            "POST",
            "/v1/rate-limit/tenant%2Fa/checkout/check",
            {
                "algorithm": "token_bucket",
                "limit": 100,
                "window_ms": 60_000,
                "refill_per_second": None,
                "cost": 2,
            },
        )
        c.rate_limit_get("tenant/a", "checkout")
        self.assert_last_call(c, "GET", "/v1/rate-limit/tenant%2Fa/checkout")

        c.schedule_upsert(
            "nightly",
            {"kind": "webhook", "url": "https://example.test/hook"},
            cron="0 0 * * *",
            delivery="exactly_once",
            max_retries=5,
        )
        self.assert_last_call(
            c,
            "PUT",
            "/v1/cron/schedules/nightly",
            {
                "cron": "0 0 * * *",
                "one_shot_at_ms": None,
                "target": {"kind": "webhook", "url": "https://example.test/hook"},
                "delivery": "exactly_once",
                "max_retries": 5,
            },
        )
        c.schedule_get("nightly")
        self.assert_last_call(c, "GET", "/v1/cron/schedules/nightly")
        c.schedule_record_run("nightly", "fire-1", fired_at_ms=123)
        self.assert_last_call(c, "POST", "/v1/cron/schedules/nightly/runs", {"fire_id": "fire-1", "fired_at_ms": 123})
        c.schedule_history("nightly")
        self.assert_last_call(c, "GET", "/v1/cron/schedules/nightly/history")

        c.election_campaign("cron-main", "node-a", 15_000)
        self.assert_last_call(c, "POST", "/v1/elections/cron-main/campaign", {"candidate": "node-a", "ttl_ms": 15_000})
        c.election_renew("cron-main", "node-a", 21)
        self.assert_last_call(c, "POST", "/v1/elections/cron-main/renew", {"candidate": "node-a", "fencing_token": 21})
        c.election_resign("cron-main", "node-a", 21)
        self.assert_last_call(c, "POST", "/v1/elections/cron-main/resign", {"candidate": "node-a", "fencing_token": 21})
        c.election_get("cron-main")
        self.assert_last_call(c, "GET", "/v1/elections/cron-main")

        c.service_register("api", "i-1", "10.0.0.1:9000", 10_000, metadata={"az": "a"})
        self.assert_last_call(
            c,
            "PUT",
            "/v1/services/api/instances/i-1",
            {"address": "10.0.0.1:9000", "ttl_ms": 10_000, "metadata": {"az": "a"}},
        )
        c.service_heartbeat("api", "i-1", ttl_ms=20_000)
        self.assert_last_call(c, "POST", "/v1/services/api/instances/i-1/heartbeat", {"ttl_ms": 20_000})
        c.service_deregister("api", "i-1")
        self.assert_last_call(c, "DELETE", "/v1/services/api/instances/i-1")
        c.service_instances("api")
        self.assert_last_call(c, "GET", "/v1/services/api")
        c.service_list()
        self.assert_last_call(c, "GET", "/v1/services")

    def test_cli_dispatches_feature_groups(self):
        cases = [
            (["health"], ("health", (), {})),
            (["lock", "acquire-many", "a", "b", "--holder", "h", "--ttl-ms", "100", "--wait"],
             ("lock_acquire_many", (["a", "b"],), {"holder": "h", "ttl_ms": 100, "wait": True})),
            (["semaphore", "acquire", "pool", "--holder", "h", "--limit", "4"],
             ("semaphore_acquire", ("pool",), {"holder": "h", "ttl_ms": None, "max": 4, "wait": False})),
            (["kv", "put", "flags/new-ui", "on", "--prev-revision", "3"],
             ("kv_put", ("flags/new-ui", "on"), {"ttl_ms": None, "prev_revision": 3})),
            (["rate-limit", "check", "tenant-a", "checkout", "--algorithm", "sliding_window", "--limit", "5", "--window-ms", "1000"],
             ("rate_limit_check", ("tenant-a", "checkout", "sliding_window", 5, 1000), {"refill_per_second": None, "cost": None})),
            (["cron", "upsert", "nightly", "--cron", "0 0 * * *", "--target-kind", "webhook", "--target-url", "https://example.test/hook"],
             ("schedule_upsert", ("nightly", {"kind": "webhook", "url": "https://example.test/hook"}), {
                 "cron": "0 0 * * *",
                 "one_shot_at_ms": None,
                 "delivery": None,
                 "max_retries": None,
             })),
            (["election", "campaign", "cron-main", "node-a", "--ttl-ms", "15000"],
             ("election_campaign", ("cron-main", "node-a", 15_000), {})),
            (["service", "register", "api", "i-1", "10.0.0.1:9000", "--ttl-ms", "10000", "--metadata", "az=a"],
             ("service_register", ("api", "i-1", "10.0.0.1:9000", 10_000), {"metadata": {"az": "a"}})),
        ]

        for argv, expected in cases:
            with self.subTest(argv=argv):
                fake = CliFake.install()
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    self.assertEqual(fiducia.main(argv, client_factory=fake.factory), 0)

                self.assertEqual(fake.calls, [expected])
                self.assertEqual(json.loads(out.getvalue()), {"ok": expected[0]})


class CliFake:
    def __init__(self):
        self.calls = []

    @classmethod
    def install(cls):
        return cls()

    def factory(self, base_url, timeout=30):
        self.base_url = base_url
        self.timeout = timeout
        return self

    def __getattr__(self, name):
        def call(*args, **kwargs):
            self.calls.append((name, args, kwargs))
            return {"ok": name}
        return call


if __name__ == "__main__":
    unittest.main()
