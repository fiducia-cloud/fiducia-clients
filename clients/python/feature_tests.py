#!/usr/bin/env python3
"""Live integration tests for the rest of fiducia's primitives, via the SDK:
config KV (+ CAS), leader election, service discovery, rate limiting, cron.

    FIDUCIA_URL=http://<lb-host>:8088 python3 feature_tests.py

Like live_tests.py, every call goes through fiducia.FiduciaClient — the wire
protocol stays in the library. Note: lock/KV keys are slash-safe (body / ?key=),
but election / service / tenant / cron names are URL *path* params, so those use
slash-free ids. Exits non-zero on any failure.
"""

import os
import sys
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fiducia import FiduciaClient, FiduciaError  # noqa: E402

BASE = os.environ.get("FIDUCIA_URL", "http://127.0.0.1:8088")
RUN = uuid.uuid4().hex[:8]
c = FiduciaClient(BASE, timeout=25)
_P = {"pass": 0, "fail": 0, "failed": []}


def key(name):       # slash-safe (KV ?key=, lock body)
    return "livetest/%s/%s" % (RUN, name)


def nid(name):       # slash-free (path-param identifiers)
    return "lt-%s-%s" % (RUN, name)


def check(name, cond, detail=""):
    if cond:
        _P["pass"] += 1
        print("  ok   %s" % name)
    else:
        _P["fail"] += 1
        _P["failed"].append(name)
        print("  FAIL %s   %s" % (name, detail))


def out(resp):
    assert resp and resp.get("committed") is True, "not committed: %r" % resp
    return resp["result"]["output"]


def section(title):
    print("\n== %s ==" % title)


# ---------------------------------------------------------------------------
def t_kv():
    section("config KV + compare-and-swap + delete")
    K = key("flags/checkout")  # slash in the key on purpose
    r1 = out(c.kv_put(K, "v1"))
    check("put ok", r1.get("ok") is True, r1)
    rev1 = r1.get("revision")
    g1 = c.kv_get(K)
    check("get returns value + revision", g1.get("found") is True
          and g1["entry"]["value"] == "v1", g1)
    bad = out(c.kv_put(K, "v2", prev_revision=rev1 + 999))
    check("CAS with wrong revision rejected", bad.get("ok") is False
          and bad.get("reason") == "cas_mismatch", bad)
    r2 = out(c.kv_put(K, "v2", prev_revision=rev1))
    check("CAS with right revision updates", r2.get("ok") is True
          and r2.get("revision") > rev1, r2)
    check("value is now v2", c.kv_get(K)["entry"]["value"] == "v2")
    d = out(c.kv_delete(K))
    check("delete ok", d.get("ok") is True, d)
    check("deleted key not found", c.kv_get(K).get("found") is False)


def t_election():
    section("leader election (campaign / observe / renew / resign + fencing)")
    name = nid("scheduler")
    a = out(c.election_campaign(name, "node-a", ttl_ms=30000))
    check("node-a wins campaign", a.get("won") is True, a)
    tok = a["leadership"]["fencing_token"]
    b = out(c.election_campaign(name, "node-b", ttl_ms=30000))
    check("node-b loses while node-a holds", b.get("won") is False, b)
    obs = c.election_get(name)
    check("observe shows leadership held", obs.get("held") is True, obs)
    stale = out(c.election_renew(name, "node-a", tok + 999))
    check("stale-token renew rejected", stale.get("renewed") is False, stale)
    ren = out(c.election_renew(name, "node-a", tok))
    check("valid renew accepted", ren.get("renewed") is True, ren)
    res = out(c.election_resign(name, "node-a", tok))
    check("resign accepted", res.get("resigned") is True, res)
    b2 = out(c.election_campaign(name, "node-b", ttl_ms=30000))
    check("node-b wins after node-a resigns", b2.get("won") is True, b2)
    out(c.election_resign(name, "node-b", b2["leadership"]["fencing_token"]))


def t_discovery():
    section("service discovery (register / lookup / metadata / heartbeat / deregister)")
    svc = nid("api")
    addr = "http://10.0.0.7:8080"
    reg = out(c.service_register(svc, "i-1", addr, ttl_ms=30000, metadata={"region": "eu-1"}))
    check("instance registered", reg.get("registered") is True, reg)
    insts = c.service_instances(svc).get("instances", [])
    found = next((i for i in insts if i.get("address") == addr), None)
    check("instance appears in lookup", found is not None, insts)
    check("metadata round-trips", (found or {}).get("metadata", {}).get("region") == "eu-1", found)
    hb = out(c.service_heartbeat(svc, "i-1"))
    check("heartbeat accepted", hb.get("heartbeat") is True, hb)
    dr = out(c.service_deregister(svc, "i-1"))
    check("deregister accepted", dr.get("deregistered") is True, dr)
    insts2 = c.service_instances(svc).get("instances", [])
    check("instance gone after deregister",
          all(i.get("address") != addr for i in insts2), insts2)


def t_rate_limit():
    section("rate limiting (token bucket, per-tenant isolation, sliding window)")
    K = "checkout"

    def tb(tenant):
        return out(c.rate_limit_check(tenant, K, "token_bucket", limit=2,
                                      window_ms=60000, refill_per_second=0.01, cost=1))
    ta = nid("ta")
    c1, c2, c3 = tb(ta), tb(ta), tb(ta)
    check("first 2 allowed under limit 2", c1.get("allowed") and c2.get("allowed"), (c1, c2))
    check("3rd request denied", c3.get("allowed") is False, c3)
    other = tb(nid("tb"))
    check("different tenant has its own bucket", other.get("allowed") is True, other)

    sw_t = nid("sw")
    s1 = out(c.rate_limit_check(sw_t, "api", "sliding_window", limit=1, window_ms=60000, cost=1))
    s2 = out(c.rate_limit_check(sw_t, "api", "sliding_window", limit=1, window_ms=60000, cost=1))
    check("sliding window: 1 allowed then denied",
          s1.get("allowed") is True and s2.get("allowed") is False, (s1, s2))


def t_cron():
    section("cron / scheduling (upsert + exactly-once fire dedupe + history)")
    name = nid("nightly")
    up = out(c.schedule_upsert(name, target={"kind": "webhook", "url": "https://example.com/hook"},
                               cron="0 0 * * *", delivery="exactly_once", max_retries=3))
    check("schedule upserted", up.get("ok") is True, up)
    g = c.schedule_get(name)
    check("schedule get found", g.get("found") is True, g)
    r1 = out(c.schedule_record_run(name, "2026-06-27T00:00Z"))
    check("first fire recorded", r1.get("recorded") is True, r1)
    r2 = out(c.schedule_record_run(name, "2026-06-27T00:00Z"))
    check("duplicate fire_id deduped (exactly-once)", r2.get("duplicate") is True, r2)
    hist = c.schedule_history(name).get("history", [])
    check("history has exactly one run", len(hist) == 1, hist)


def main():
    print("fiducia feature tests via Python SDK -> %s (run %s)" % (BASE, RUN))
    for t in (t_kv, t_election, t_discovery, t_rate_limit, t_cron):
        try:
            t()
        except (FiduciaError, AssertionError, Exception) as e:  # noqa: BLE001
            _P["fail"] += 1
            _P["failed"].append(t.__name__)
            print("  FAIL %s raised: %r" % (t.__name__, e))
    print("\n==== %d passed, %d failed ====" % (_P["pass"], _P["fail"]))
    if _P["failed"]:
        print("failed: %s" % ", ".join(_P["failed"]))
        sys.exit(1)


if __name__ == "__main__":
    main()
