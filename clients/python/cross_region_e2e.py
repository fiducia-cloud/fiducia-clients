#!/usr/bin/env python3
"""Deep client -> regional LB -> Raft node end-to-end tests using the real Python SDK.

Requires TWO separate nonproduction regional load-balancer endpoints backed by
the same quorum. No mocked SDK, HTTP fixtures or implicit skips:

  FIDUCIA_E2E_ENDPOINTS=http://127.0.0.1:8088,http://127.0.0.1:8089 \
  FIDUCIA_E2E_ALLOW_WRITES=1 python3 clients/python/cross_region_e2e.py

Writes use unique names and are cleaned up where possible. The deployed
Python client currently supports anonymous/internal endpoints, not public
bearer auth. Do not run this against production.
"""
from __future__ import annotations

import concurrent.futures
import os
import threading
import unittest
import uuid
from urllib.parse import urlsplit

from fiducia import FiduciaClient


def endpoints_from_env():
    origins = [s.strip().rstrip("/") for s in os.getenv("FIDUCIA_E2E_ENDPOINTS", "").split(",") if s.strip()]
    if len(origins) != 2 or origins[0] == origins[1]:
        raise RuntimeError("FIDUCIA_E2E_ENDPOINTS must contain two DISTINCT regional LB origins")
    if os.getenv("FIDUCIA_E2E_ALLOW_WRITES") != "1":
        raise RuntimeError("set FIDUCIA_E2E_ALLOW_WRITES=1 on a nonproduction cluster")
    for origin in origins:
        url = urlsplit(origin)
        if url.scheme not in ("http", "https") or not url.hostname or url.path not in ("", "/"):
            raise ValueError("expected HTTP(S) origin URL: %r" % origin)
    return origins


def output(response):
    if not isinstance(response, dict) or response.get("committed") is not True:
        raise AssertionError("server never committed the request: %r" % response)
    result = response.get("result")
    if not isinstance(result, dict) or not isinstance(result.get("output"), dict):
        raise AssertionError("missing committed output: %r" % response)
    return result["output"]


class CrossRegionE2E(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        urls = endpoints_from_env()
        cls.clients = [FiduciaClient(url, timeout=8, max_retries=0) for url in urls]
        cls.prefix = "e2e/" + uuid.uuid4().hex
        for index, client in enumerate(cls.clients):
            health = client.health()
            if not isinstance(health, dict):
                raise AssertionError("region %s gave no JSON health: %r" % (index, health))

    def key(self, name):
        return "%s/%s" % (self.prefix, name)

    def test_kv_read_after_ack_and_cas_across_regions(self):
        a, b = self.clients
        key = self.key("kv/causal")
        created = output(a.kv_put(key, "created-a", prev_revision=0))
        self.assertIs(created.get("ok"), True, created)
        old_rev = created["revision"]
        self.assertGreater(old_rev, 0)
        try:
            # A follower/remote LB must not return a value older than a
            # previously acknowledged write from another region.
            remote = b.kv_get(key)
            self.assertIs(remote.get("found"), True, remote)
            self.assertEqual(remote["entry"]["value"], "created-a")
            stale = output(b.kv_put(key, "lost-update", prev_revision=0))
            self.assertIs(stale.get("ok"), False, stale)
            self.assertEqual(stale.get("reason"), "cas_mismatch")
            updated = output(b.kv_put(key, "updated-b", prev_revision=old_rev))
            self.assertIs(updated.get("ok"), True, updated)
            self.assertGreater(updated["revision"], old_rev)
            self.assertEqual(a.kv_get(key)["entry"]["value"], "updated-b")
        finally:
            deleted = output(b.kv_delete(key))
            self.assertIs(deleted.get("ok"), True, deleted)
        self.assertIs(a.kv_get(key).get("found"), False)

    def test_two_regions_never_double_grant_one_lock(self):
        a, b = self.clients
        key = self.key("locks/race")
        gate = threading.Barrier(2, timeout=10)

        def contend(client, holder):
            gate.wait()
            return holder, output(client.lock_acquire(
                key, holder=holder, ttl_ms=30000, wait=False))

        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(contend, a, "region-a"),
                       pool.submit(contend, b, "region-b")]
            responses = [future.result(timeout=20) for future in futures]
        winners = [(h, r) for h, r in responses if r.get("acquired") is True]
        self.assertEqual(len(winners), 1, responses)
        self.assertEqual(sum(r.get("acquired") is False for _, r in responses), 1)
        holder, grant = winners[0]
        old_token = grant["fencing_token"]
        other = b if holder == "region-a" else a

        try:
            release = output(other.lock_release(holder, old_token))
            self.assertIs(release.get("released"), True, release)
            after = output(other.lock_acquire(
                key, holder="after-handoff", ttl_ms=30000, wait=False))
            self.assertIs(after.get("acquired"), True, after)
            new_token = after["fencing_token"]
            self.assertGreater(new_token, old_token)
            try:
                stale = output(a.lock_release(holder, old_token))
                self.assertIs(stale.get("released"), False, stale)
                intruder = output(a.lock_acquire(
                    key, holder="intruder", ttl_ms=3000, wait=False))
                self.assertIs(intruder.get("acquired"), False, intruder)
                self.assertEqual(a.lock_get(key)["lock"]["holder"], "after-handoff")
            finally:
                released = output(a.lock_release("after-handoff", new_token))
                self.assertIs(released.get("released"), True, released)
        except BaseException:
            try:
                other.lock_release(holder, old_token)
            except Exception:
                pass
            raise

    def test_global_semaphore_capacity_across_regional_load_balancers(self):
        a, b = self.clients
        key = self.key("semaphores/race")
        capacity, n = 3, 10
        gate = threading.Barrier(n, timeout=12)

        def contend(i):
            gate.wait()
            holder = "worker-" + str(i)
            response = (a, b)[i % 2].semaphore_acquire(
                key, limit=capacity, holder=holder, ttl_ms=45000, wait=False)
            return holder, output(response)

        failures, responses = [], []
        with concurrent.futures.ThreadPoolExecutor(max_workers=n) as pool:
            futures = [pool.submit(contend, i) for i in range(n)]
            for future in futures:
                try:
                    responses.append(future.result(timeout=20))
                except Exception as error:
                    failures.append(repr(error))
        winners = [(holder, result) for holder, result in responses
                   if result.get("acquired") is True]
        try:
            self.assertFalse(failures, failures)
            self.assertEqual(len(winners), capacity, responses)
            self.assertEqual(len({r["fencing_token"] for _, r in winners}), capacity)
            for client in self.clients:
                state = client.semaphore_get(key)["semaphore"]
                self.assertEqual(len(state["holders"]), capacity, state)
                self.assertEqual(state["available"], 0, state)
        finally:
            for holder, result in winners:
                try:
                    output(b.semaphore_release(key, holder, result["fencing_token"]))
                except Exception:
                    pass
        self.assertEqual(a.semaphore_get(key)["semaphore"]["available"], capacity)

    def test_election_leadership_handoff_and_stale_fence(self):
        a, b = self.clients
        name = "e2e-" + uuid.uuid4().hex  # path-segment safe
        first = output(a.election_campaign(name, "primary", ttl_ms=30000))
        self.assertIs(first.get("won"), True, first)
        old_token = first["leadership"]["fencing_token"]
        try:
            other = output(b.election_campaign(name, "standby", ttl_ms=30000))
            self.assertIs(other.get("won"), False, other)
            stale = output(b.election_renew(name, "primary", old_token + 100))
            self.assertIs(stale.get("renewed"), False, stale)
            resign = output(b.election_resign(name, "primary", old_token))
            self.assertIs(resign.get("resigned"), True, resign)
            second = output(b.election_campaign(name, "standby", ttl_ms=30000))
            self.assertIs(second.get("won"), True, second)
            new_token = second["leadership"]["fencing_token"]
            self.assertGreater(new_token, old_token)
            try:
                stale = output(a.election_renew(name, "primary", old_token))
                self.assertIs(stale.get("renewed"), False, stale)
                self.assertIs(a.election_get(name).get("held"), True)
            finally:
                resign = output(a.election_resign(name, "standby", new_token))
                self.assertIs(resign.get("resigned"), True, resign)
        except BaseException:
            try:
                a.election_resign(name, "primary", old_token)
            except Exception:
                pass
            raise


if __name__ == "__main__":
    unittest.main(verbosity=2)
