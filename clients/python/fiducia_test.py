# Unit tests for the generated Fiducia Python client.
import contextlib
import io
import json
import os
import pathlib
import re
import sys
import unittest
import unittest.mock

sys.path.insert(0, os.path.dirname(__file__))

import fiducia  # noqa: E402
import cli as fiducia_cli  # noqa: E402


class RecordingClient(fiducia.FiduciaClient):
    def __init__(self, base_url="https://fiducia.test", timeout=30):
        super().__init__(base_url, timeout=timeout)
        self.calls = []

    def _request(self, method, path, body=None, **request_opts):
        self.calls.append((method, path, body, request_opts))
        return {"method": method, "path": path, "body": body}

    def _watch(self, path, **request_opts):
        self.calls.append(("WATCH", path, None, request_opts))
        return iter(())


class FiduciaPythonClientTests(unittest.TestCase):
    def assert_last_call(self, client, method, path, body=None):
        self.assertEqual(client.calls[-1], (method, path, body, {}))

    def assert_last_call_with_opts(self, client, method, path, body=None, request_opts=None):
        self.assertEqual(client.calls[-1], (method, path, body, request_opts or {}))

    def test_request_opts_send_idempotency_key_header(self):
        captured = {}

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b'{"ok": true}'

        def fake_urlopen(req, timeout):
            captured["method"] = req.get_method()
            captured["headers"] = {key.lower(): value for key, value in req.header_items()}
            captured["body"] = json.loads(req.data.decode())
            captured["timeout"] = timeout
            return Response()

        client = fiducia.FiduciaClient("https://fiducia.test", timeout=9)
        with unittest.mock.patch.object(fiducia.urllib.request, "urlopen", fake_urlopen):
            self.assertEqual(
                client.kv_put("orders/42", "paid", idempotency_key="req_order_42"),
                {"ok": True},
            )

        self.assertEqual(captured["method"], "PUT")
        self.assertEqual(captured["headers"]["idempotency-key"], "req_order_42")
        self.assertEqual(captured["headers"]["content-type"], "application/json")
        self.assertEqual(captured["body"], {"value": "paid", "ttl_ms": None, "prev_revision": None})
        self.assertEqual(captured["timeout"], 9)

    def test_sdk_sources_use_live_lock_semaphore_and_kv_routes(self):
        repo = pathlib.Path(__file__).resolve().parents[2]
        sources = [
            "clients/csharp/Fiducia.cs",
            "clients/dart/fiducia.dart",
            "clients/elixir/fiducia.ex",
            "clients/go/fiducia.go",
            "clients/java/Fiducia.java",
            "clients/php/Fiducia.php",
            "clients/powershell/Fiducia.psm1",
            "clients/python/fiducia.py",
            "clients/ruby/fiducia.rb",
            "clients/rust/src/lib.rs",
            "clients/shell/fiducia.sh",
            "clients/ts/fiducia.ts",
        ]
        path_key_action = re.compile(r"/v1/(?:locks|semaphores)/.+/(?:acquire|release)")

        for rel in sources:
            with self.subTest(source=rel):
                text = (repo / rel).read_text()
                self.assertIsNone(path_key_action.search(text))
                self.assertNotIn("/v1/kv/", text)
                self.assertNotIn("/v1/locks/acquire-many", text)
                self.assertNotIn("/v1/locks/release-many", text)

    def test_sdk_routes_cover_coordination_primitives(self):
        c = RecordingClient()

        c.lock_get("orders/42")
        self.assert_last_call(c, "GET", "/v1/locks?key=orders%2F42")
        c.lock_acquire("orders/42", holder="worker-a", ttl_ms=30_000, wait=True)
        self.assert_last_call(
            c,
            "POST",
            "/v1/locks/acquire",
            {"key": "orders/42", "holder": "worker-a", "ttl_ms": 30_000, "wait": True},
        )
        c.lock_acquire_many(["orders/42", "inventory/sku-7"], holder="worker-a")
        self.assert_last_call(
            c,
            "POST",
            "/v1/locks/acquire",
            {"keys": ["orders/42", "inventory/sku-7"], "holder": "worker-a", "ttl_ms": None, "wait": None},
        )
        c.lock_release("worker-a", 12)
        self.assert_last_call(c, "POST", "/v1/locks/release", {"holder": "worker-a", "fencing_token": 12})

        c.semaphore_get("pools/db/primary")
        self.assert_last_call(c, "GET", "/v1/semaphores?key=pools%2Fdb%2Fprimary")
        c.semaphore_acquire("pools/db/primary", 3, holder="worker-b", ttl_ms=20_000, wait=True)
        self.assert_last_call(
            c,
            "POST",
            "/v1/semaphores/acquire",
            {"key": "pools/db/primary", "holder": "worker-b", "ttl_ms": 20_000, "wait": True, "limit": 3},
        )
        c.semaphore_acquire("pools/db/primary", 4, holder="worker-c", ttl_ms=20_000, wait=True)
        self.assert_last_call(
            c,
            "POST",
            "/v1/semaphores/acquire",
            {"key": "pools/db/primary", "holder": "worker-c", "ttl_ms": 20_000, "wait": True, "limit": 4},
        )
        c.semaphore_release("pools/db/primary", "worker-b", 12)
        self.assert_last_call(
            c,
            "POST",
            "/v1/semaphores/release",
            {"key": "pools/db/primary", "holder": "worker-b", "fencing_token": 12},
        )

        c.idempotency_get("stripe-webhook/event_123")
        self.assert_last_call(c, "GET", "/v1/idempotency?key=stripe-webhook%2Fevent_123")
        c.idempotency_claim(
            "stripe-webhook/event_123",
            owner="worker-a",
            ttl="24h",
            metadata={"source": "stripe"},
        )
        self.assert_last_call(
            c,
            "POST",
            "/v1/idempotency/claim",
            {
                "key": "stripe-webhook/event_123",
                "owner": "worker-a",
                "ttl_ms": None,
                "ttl": "24h",
                "metadata": {"source": "stripe"},
            },
        )
        c.idempotency_complete("stripe-webhook/event_123", "worker-a", 11, result={"status": "ok"})
        self.assert_last_call(
            c,
            "POST",
            "/v1/idempotency/complete",
            {
                "key": "stripe-webhook/event_123",
                "owner": "worker-a",
                "fencing_token": 11,
                "result": {"status": "ok"},
            },
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

        c.election_campaign("cron-main", "node-a", 15_000, metadata={"region": "us-east-1"})
        self.assert_last_call(
            c,
            "POST",
            "/v1/elections/cron-main/campaign",
            {"candidate": "node-a", "ttl_ms": 15_000, "metadata": {"region": "us-east-1"}},
        )
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
        c.service_instances("api", metadata={"region": "eu central", "version": "blue/1"})
        self.assert_last_call(c, "GET", "/v1/services/api?metadata.region=eu+central&metadata.version=blue%2F1")
    def test_cli_dispatches_feature_groups(self):
        cases = [
            (["health"], ("health", (), {})),
            (["lock", "acquire", "--keys", "a,b", "--holder", "h", "--ttl-ms", "100", "--wait"],
             ("lock_acquire_many", (["a", "b"],), {"holder": "h", "ttl_ms": 100, "wait": True})),
            (["sem", "acquire", "--key", "pool", "--holder", "h", "--limit", "4"],
             ("semaphore_acquire", ("pool", 4), {"holder": "h", "ttl_ms": None, "wait": False})),
            (["kv", "put", "--key", "flags/new-ui", "--value", "on", "--prev-revision", "3"],
             ("kv_put", ("flags/new-ui", "on"), {"ttl_ms": None, "prev_revision": 3})),
            (["ratelimit", "check", "--tenant", "tenant-a", "--key", "checkout", "--algorithm", "sliding_window", "--limit", "5", "--window-ms", "1000"],
             ("rate_limit_check", ("tenant-a", "checkout", "sliding_window", 5, 1000), {"refill_per_second": None, "cost": None})),
            (["cron", "upsert", "--name", "nightly", "--cron", "0 0 * * *", "--webhook", "https://example.test/hook"],
             ("schedule_upsert", ("nightly", {"kind": "webhook", "url": "https://example.test/hook"}), {
                 "cron": "0 0 * * *",
                 "one_shot_at_ms": None,
                 "delivery": None,
                 "max_retries": None,
             })),
            (["election", "campaign", "--name", "cron-main", "--candidate", "node-a", "--ttl-ms", "15000"],
             ("election_campaign", ("cron-main", "node-a", 15_000), {})),
            (["service", "register", "--service", "api", "--id", "i-1", "--address", "10.0.0.1:9000", "--ttl-ms", "10000", "--meta", "az=a"],
             ("service_register", ("api", "i-1", "10.0.0.1:9000", 10_000), {"metadata": {"az": "a"}})),
            (["service", "list", "--service", "api"],
             ("service_instances", ("api",), {})),
        ]

        for argv, expected in cases:
            with self.subTest(argv=argv):
                fake = CliFake.install()
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    self.assertEqual(fiducia_cli.main(argv, client_factory=fake.factory), 0)

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
