# Unit tests for the generated Fiducia Python client.
import contextlib
import io
import json
import os
import pathlib
import re
import sys
import threading
import unittest
import unittest.mock
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(__file__))

import fiducia  # noqa: E402
import cli as fiducia_cli  # noqa: E402
import locking as fiducia_locking  # noqa: E402


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

    def test_omitted_holder_is_generated_securely(self):
        client = RecordingClient()
        client.try_lock("orders/42")
        first = client.calls[-1][2]["holder"]
        client.try_lock("orders/43")
        second = client.calls[-1][2]["holder"]
        self.assertRegex(first, r"^fdc-[0-9a-f]{32}$")
        self.assertNotEqual(first, second)

    def test_attempt_request_id_validation(self):
        with self.assertRaisesRegex(ValueError, "1-128 printable UTF-8 bytes"):
            fiducia._validate_attempt_request_ids({"request_id": "   "})
        with self.assertRaisesRegex(ValueError, "1-128 printable UTF-8 bytes"):
            fiducia._validate_attempt_request_ids({"request_id": "x" * 129})
        fiducia._validate_attempt_request_ids({"request_id": "fdc-attempt-123"})

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
        with unittest.mock.patch.object(fiducia, "_urlopen", fake_urlopen):
            self.assertEqual(
                client.kv_put("orders/42", "paid", idempotency_key="req_order_42"),
                {"ok": True},
            )

        self.assertEqual(captured["method"], "PUT")
        self.assertEqual(captured["headers"]["idempotency-key"], "req_order_42")
        self.assertEqual(captured["headers"]["content-type"], "application/json")
        self.assertEqual(captured["body"], {"value": "paid"})
        self.assertEqual(captured["timeout"], 9)

    def test_keyless_post_is_not_retried(self):
        calls = []

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b'{"ok": true}'

        def flaky_urlopen(req, timeout):
            del timeout
            headers = {key.lower(): value for key, value in req.header_items()}
            calls.append(headers.get("idempotency-key"))
            if len(calls) == 1:
                raise urllib.error.URLError("response lost")
            return Response()

        client = fiducia.FiduciaClient("https://fiducia.test", max_retries=1)
        with unittest.mock.patch.object(fiducia, "_urlopen", flaky_urlopen), self.assertRaises(urllib.error.URLError):
            client.try_lock("orders/42", holder="worker-a")

        self.assertEqual(calls, [None])

    def test_retry_keeps_caller_key_but_leaves_get_and_single_shot_post_keyless(self):
        calls = []

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b'{"ok": true}'

        def record(req, timeout):
            del timeout
            headers = {key.lower(): value for key, value in req.header_items()}
            calls.append((req.get_method(), headers.get("idempotency-key")))
            return Response()

        with unittest.mock.patch.object(fiducia, "_urlopen", record):
            retrying = fiducia.FiduciaClient("https://fiducia.test", max_retries=1)
            retrying.try_lock(
                "orders/42",
                holder="worker-a",
                idempotency_key="caller-key",
            )
            retrying.lock_get("orders/42")
            fiducia.FiduciaClient("https://fiducia.test").try_lock(
                "orders/43",
                holder="worker-a",
            )

        self.assertEqual(
            calls,
            [("POST", "caller-key"), ("GET", None), ("POST", None)],
        )

    def test_redirect_is_not_followed_or_retried(self):
        hits = {"source": 0, "target": 0}

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                hits["source"] += 1
                self.send_response(302)
                self.send_header("location", "/stolen")
                self.end_headers()

            def do_GET(self):
                hits["target"] += 1
                self.send_response(200)
                self.send_header("content-type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"stolen": true}')

            def log_message(self, *_args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            client = fiducia.FiduciaClient(
                "http://127.0.0.1:%d" % server.server_port,
                max_retries=3,
            )
            with self.assertRaises(fiducia.FiduciaError) as raised:
                client.try_lock("orders/42", holder="worker-a")
            self.assertEqual(raised.exception.status, 302)
            self.assertEqual(raised.exception.body["error"], "redirect_not_followed")
            self.assertEqual(raised.exception.body["location"], "/stolen")
            self.assertEqual(hits, {"source": 1, "target": 0})
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_plain_text_503_preserves_status_and_retries_with_one_key(self):
        calls = []

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b'{"ok": true}'

        def flaky(req, timeout):
            del timeout
            headers = {key.lower(): value for key, value in req.header_items()}
            calls.append(headers.get("idempotency-key"))
            if len(calls) == 1:
                raise urllib.error.HTTPError(
                    req.full_url,
                    503,
                    "unavailable",
                    {},
                    io.BytesIO(b"proxy temporarily unavailable"),
                )
            return Response()

        client = fiducia.FiduciaClient("https://fiducia.test", max_retries=1)
        with unittest.mock.patch.object(fiducia, "_urlopen", flaky):
            self.assertEqual(
                client.try_lock(
                    "orders/42",
                    holder="worker-a",
                    idempotency_key="caller-key",
                ),
                {"ok": True},
            )
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls, ["caller-key", "caller-key"])

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
            {"key": "orders/42", "holder": "worker-a", "ttl_ms": 30_000, "wait": True,
             "wait_timeout_ms": None, "request_id": None, "max": None},
        )
        c.lock_acquire_many(["orders/42", "inventory/sku-7"], holder="worker-a")
        self.assert_last_call(
            c,
            "POST",
            "/v1/locks/acquire",
            {"keys": ["orders/42", "inventory/sku-7"], "holder": "worker-a", "ttl_ms": None,
             "wait": False, "wait_timeout_ms": None, "request_id": None},
        )
        c.lock_renew(["orders/42"], "worker-a", 12, 30_000)
        self.assert_last_call(
            c, "POST", "/v1/locks/renew",
            {"keys": ["orders/42"], "holder": "worker-a", "fencing_token": 12, "ttl_ms": 30_000},
        )
        c.lock_cancel(["orders/42"], "worker-a")
        self.assert_last_call(
            c, "POST", "/v1/locks/cancel",
            {"keys": ["orders/42"], "holder": "worker-a", "request_id": None},
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
            {"key": "pools/db/primary", "holder": "worker-b", "ttl_ms": 20_000,
             "wait": True, "wait_timeout_ms": None, "request_id": None, "limit": 3},
        )
        c.semaphore_acquire("pools/db/primary", 4, holder="worker-c", ttl_ms=20_000, wait=True)
        self.assert_last_call(
            c,
            "POST",
            "/v1/semaphores/acquire",
            {"key": "pools/db/primary", "holder": "worker-c", "ttl_ms": 20_000,
             "wait": True, "wait_timeout_ms": None, "request_id": None, "limit": 4},
        )
        c.semaphore_renew("pools/db/primary", "worker-b", 12, 20_000)
        self.assert_last_call(
            c, "POST", "/v1/semaphores/renew",
            {"key": "pools/db/primary", "holder": "worker-b", "fencing_token": 12,
             "ttl_ms": 20_000},
        )
        c.semaphore_cancel("pools/db/primary", "worker-b")
        self.assert_last_call(
            c, "POST", "/v1/semaphores/cancel",
            {"key": "pools/db/primary", "holder": "worker-b", "request_id": None},
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
        c.kv_put("flags/new-ui", "on", ttl_ms=60_000, prev_revision=7, plaintext=True)
        self.assert_last_call(
            c,
            "PUT",
            "/v1/kv?key=flags%2Fnew-ui",
            {"value": "on", "ttl_ms": 60_000, "prev_revision": 7, "plaintext": True},
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
            (["kv", "put", "--key", "flags/new-ui", "--value", "on", "--prev-revision", "3", "--plaintext"],
             ("kv_put", ("flags/new-ui", "on"), {"ttl_ms": None, "prev_revision": 3, "plaintext": True})),
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


class AttemptRecordingLockClient(fiducia_locking.FiduciaLockClient):
    def __init__(self):
        super().__init__("https://fiducia.test")
        self.attempt_calls = []

    def lock_acquire_many(self, keys, **kwargs):
        self.attempt_calls.append(("lock_acquire", list(keys), kwargs))
        return {"result": {"output": {"acquired": False, "queued": True}}}

    def lock_cancel(self, keys, holder, request_id=None, **request_opts):
        self.attempt_calls.append(("lock_cancel", list(keys), {
            "holder": holder, "request_id": request_id, **request_opts,
        }))
        return {"result": {"output": {"cancelled": True, "acquired": False}}}

    def semaphore_acquire(self, key, limit, **kwargs):
        self.attempt_calls.append(("semaphore_acquire", (key, limit), kwargs))
        return {"result": {"output": {"acquired": False, "queued": True}}}

    def semaphore_cancel(self, key, holder, request_id=None, **request_opts):
        self.attempt_calls.append(("semaphore_cancel", key, {
            "holder": holder, "request_id": request_id, **request_opts,
        }))
        return {"result": {"output": {"cancelled": True, "acquired": False}}}


class FiduciaAttemptIdentityTests(unittest.TestCase):
    def test_lock_attempt_reuses_one_random_id_for_retries_and_cancel(self):
        client = AttemptRecordingLockClient()
        with self.assertRaises(fiducia_locking.LockTimeout):
            client.lock(
                ["orders/42"], holder="stable-worker", max_wait_ms=50,
                retry_interval_ms=0, max_retries=1,
            )

        acquire_ids = [
            call[2]["request_id"] for call in client.attempt_calls
            if call[0] == "lock_acquire"
        ]
        cancel_id = next(call[2]["request_id"] for call in client.attempt_calls
                         if call[0] == "lock_cancel")
        self.assertEqual(len(acquire_ids), 2)
        self.assertEqual(set(acquire_ids), {cancel_id})
        self.assertRegex(cancel_id, r"^fdc-attempt-[0-9a-f]{32}$")

    def test_cancellation_capacity_is_surfaced_as_unsafe(self):
        class CapacityClient(AttemptRecordingLockClient):
            def lock_cancel(self, keys, holder, request_id=None, **request_opts):
                del keys, holder, request_id, request_opts
                return {"result": {"output": {
                    "cancelled": False,
                    "acquired": False,
                    "reason": "cancellation_capacity",
                }}}

            def semaphore_cancel(self, key, holder, request_id=None, **request_opts):
                del key, holder, request_id, request_opts
                return {"result": {"output": {
                    "cancelled": False,
                    "acquired": False,
                    "reason": "cancellation_capacity",
                }}}

        client = CapacityClient()
        with self.assertRaisesRegex(RuntimeError, "cancellation_capacity"):
            client.lock(
                "orders/42", holder="stable-worker", max_wait_ms=10,
                retry_interval_ms=0, max_retries=0,
            )
        with self.assertRaisesRegex(RuntimeError, "cancellation_capacity"):
            client.acquire_semaphore(
                "pool", 2, holder="stable-worker", max_wait_ms=10,
                retry_interval_ms=0, max_retries=0,
            )
    def test_semaphore_attempt_reuses_one_random_id_for_retries_and_cancel(self):
        client = AttemptRecordingLockClient()
        with self.assertRaises(fiducia_locking.LockTimeout):
            client.acquire_semaphore(
                "pool", 2, holder="stable-worker", max_wait_ms=50,
                retry_interval_ms=0, max_retries=1,
            )

        acquire_ids = [
            call[2]["request_id"] for call in client.attempt_calls
            if call[0] == "semaphore_acquire"
        ]
        cancel_id = next(call[2]["request_id"] for call in client.attempt_calls
                         if call[0] == "semaphore_cancel")
        self.assertEqual(len(acquire_ids), 2)
        self.assertEqual(set(acquire_ids), {cancel_id})


class ReacquiredLockClient(AttemptRecordingLockClient):
    def lock_acquire_many(self, keys, **kwargs):
        self.attempt_calls.append(("lock_acquire", list(keys), kwargs))
        return {"result": {"output": {
            "acquired": True, "queued": False, "renewed": False,
            "fencing_token": 71, "lease_expires_ms": 100,
        }}}

    def lock_renew(self, keys, holder, fencing_token, ttl_ms, **request_opts):
        self.attempt_calls.append(("lock_renew", list(keys), {
            "holder": holder, "fencing_token": fencing_token, "ttl_ms": ttl_ms,
            **request_opts,
        }))
        return {"result": {"output": {
            "renewed": True, "fencing_token": fencing_token,
            "lease_expires_ms": 200,
        }}}

    def semaphore_acquire(self, key, limit, **kwargs):
        self.attempt_calls.append(("semaphore_acquire", (key, limit), kwargs))
        return {"result": {"output": {
            "acquired": True, "queued": False, "renewed": False,
            "fencing_token": 72, "lease_expires_ms": 300,
        }}}

    def semaphore_renew(self, key, holder, fencing_token, ttl_ms, **request_opts):
        self.attempt_calls.append(("semaphore_renew", key, {
            "holder": holder, "fencing_token": fencing_token, "ttl_ms": ttl_ms,
            **request_opts,
        }))
        return {"result": {"output": {
            "renewed": True, "fencing_token": fencing_token,
            "lease_expires_ms": 400,
        }}}


class FiduciaInitialReacquireTests(unittest.TestCase):
    def test_initial_idempotent_reacquire_is_token_renewed_before_return(self):
        client = ReacquiredLockClient()
        handle = client.try_lock("orders/42", holder="stable-worker", ttl_ms=30_000)
        self.assertIsNotNone(handle)
        self.assertEqual(handle.lease_expires_ms, 200)
        self.assertEqual([call[0] for call in client.attempt_calls], [
            "lock_acquire", "lock_renew",
        ])

        client.attempt_calls.clear()
        permit = client.try_semaphore("pool", 2, holder="stable-worker", ttl_ms=30_000)
        self.assertIsNotNone(permit)
        self.assertEqual(permit.lease_expires_ms, 400)
        self.assertEqual([call[0] for call in client.attempt_calls], [
            "semaphore_acquire", "semaphore_renew",
        ])


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
