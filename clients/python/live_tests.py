#!/usr/bin/env python3
"""Live integration tests for fiducia locks / semaphores / multi-key UNION locks.

Runs ENTIRELY through the Python client SDK (fiducia.FiduciaClient) — no raw HTTP
here — so the wire protocol stays encapsulated in the library. Point it at a
deployed cluster's load balancer:

    FIDUCIA_URL=http://<lb-host>:8088 python3 live_tests.py

Scenarios are modelled on live-mutex-rs's suite (mutual exclusion, fencing,
FIFO fairness, contention/linearizability) plus fiducia's flagship multi-key
union locks and counting semaphores. Exits non-zero if any check fails.
"""

import os
import sys
import threading
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fiducia import FiduciaClient, FiduciaError  # noqa: E402

BASE = os.environ.get("FIDUCIA_URL", "http://127.0.0.1:8088")
RUN = uuid.uuid4().hex[:8]
c = FiduciaClient(BASE, timeout=25)

_P = {"pass": 0, "fail": 0, "failed": []}


def key(name):
    # Deliberately slash-containing — keys must be slash-safe (body / ?key=).
    return "livetest/%s/%s" % (RUN, name)


def check(name, cond, detail=""):
    if cond:
        _P["pass"] += 1
        print("  ok   %s" % name)
    else:
        _P["fail"] += 1
        _P["failed"].append(name)
        print("  FAIL %s   %s" % (name, detail))


def out(resp):
    """Unwrap the Raft commit envelope -> the lock/semaphore outcome."""
    assert resp and resp.get("committed") is True, "not committed: %r" % resp
    return resp["result"]["output"]


def section(title):
    print("\n== %s ==" % title)


# ---------------------------------------------------------------------------
def t_cluster_up():
    section("cluster liveness")
    h = c.health()
    check("health ok", isinstance(h, dict))
    st = c.status()
    shard0 = st.get("consensus", {}).get("shards", [{}])[0]
    check("one shard, has a role", shard0.get("role") in ("leader", "follower"),
          "status=%r" % st)


def t_basic_mutex():
    section("basic mutual exclusion + fencing")
    K = key("mutex")
    a = out(c.lock_acquire(K, holder="A", ttl_ms=30000))
    check("A acquires", a.get("acquired") is True, a)
    tok = a.get("fencing_token")
    check("fencing token issued", isinstance(tok, int) and tok > 0, a)

    b = out(c.lock_acquire(K, holder="B", ttl_ms=30000, wait=False))
    check("B blocked (held by A)", b.get("acquired") is False, b)
    check("B sees conflict on K", K in (b.get("conflicts") or []), b)

    r = out(c.lock_release("A", tok))
    check("A releases", r.get("released") is True, r)

    b2 = out(c.lock_acquire(K, holder="B", ttl_ms=30000))
    check("B acquires after release", b2.get("acquired") is True, b2)
    check("fencing token monotonic", b2.get("fencing_token") > tok, (tok, b2))
    out(c.lock_release("B", b2["fencing_token"]))


def t_release_errors():
    section("release validation")
    K = key("relerr")
    a = out(c.lock_acquire(K, holder="A", ttl_ms=30000))
    tok = a["fencing_token"]
    bad = out(c.lock_release("A", tok + 999999))
    check("release wrong token -> not_found", bad.get("released") is False
          and bad.get("reason") == "not_found", bad)
    wrong = out(c.lock_release("someone-else", tok))
    check("release wrong holder -> not_holder", wrong.get("released") is False
          and wrong.get("reason") == "not_holder", wrong)
    out(c.lock_release("A", tok))


def t_multikey_union():
    section("multi-key UNION locks (flagship)")
    a, b, g, d = key("alpha"), key("beta"), key("gamma"), key("delta")

    g1 = out(c.lock_acquire_many([a, b], holder="A", ttl_ms=30000))
    check("A locks union {alpha,beta}", g1.get("acquired") is True, g1)
    ta = g1["fencing_token"]

    # Overlapping set {beta,gamma} must be blocked by the shared key beta.
    bg = out(c.lock_acquire_many([b, g], holder="B", wait=False))
    check("B {beta,gamma} blocked on beta", bg.get("acquired") is False
          and b in (bg.get("conflicts") or []), bg)

    # Disjoint set {gamma,delta} coexists with A's {alpha,beta}.
    g2 = out(c.lock_acquire_many([g, d], holder="C", ttl_ms=30000))
    check("C {gamma,delta} acquires (disjoint)", g2.get("acquired") is True, g2)
    tc = g2["fencing_token"]

    # Free beta; {beta,gamma} still blocked because gamma is held by C.
    out(c.lock_release("A", ta))
    bg2 = out(c.lock_acquire_many([b, g], holder="B", wait=False))
    check("B {beta,gamma} still blocked on gamma", bg2.get("acquired") is False
          and g in (bg2.get("conflicts") or []), bg2)

    # Free gamma; now the whole union is grantable.
    out(c.lock_release("C", tc))
    bg3 = out(c.lock_acquire_many([b, g], holder="B", ttl_ms=30000))
    check("B {beta,gamma} acquires once both free", bg3.get("acquired") is True, bg3)
    out(c.lock_release("B", bg3["fencing_token"]))


def t_fifo_fairness():
    section("FIFO fairness + promote-on-release")
    K = key("fifo")
    a = out(c.lock_acquire(K, holder="A", ttl_ms=30000))
    ta = a["fencing_token"]
    qb = out(c.lock_acquire(K, holder="B", wait=True))
    check("B queued position 1", qb.get("queued") is True and qb.get("position") == 1, qb)
    qc = out(c.lock_acquire(K, holder="C", wait=True))
    check("C queued position 2", qc.get("queued") is True and qc.get("position") == 2, qc)

    view = c.lock_get(K)["lock"]
    check("inspect shows holder A", view.get("holder") == "A", view)
    wq = [w["holder"] for w in view.get("wait_queue", [])]
    check("inspect shows FIFO queue [B,C]", wq == ["B", "C"], wq)

    rel = out(c.lock_release("A", ta))
    promoted = [p["holder"] for p in rel.get("promoted", [])]
    check("releasing A promotes B (FIFO head)", "B" in promoted, rel)
    view2 = c.lock_get(K)["lock"]
    check("B now holds, C still queued", view2.get("holder") == "B"
          and [w["holder"] for w in view2.get("wait_queue", [])] == ["C"], view2)
    # drain
    out(c.lock_release("B", view2["fencing_token"]))
    v3 = c.lock_get(K)["lock"]
    if v3.get("holder") == "C":
        out(c.lock_release("C", v3["fencing_token"]))


def t_semaphore_cap():
    section("counting semaphore cap")
    S = key("sem")
    a = out(c.semaphore_acquire(S, limit=3, holder="A", ttl_ms=30000))
    check("A permit 1/3 (available 2)", a.get("acquired") is True and a.get("available") == 2, a)
    out(c.semaphore_acquire(S, limit=3, holder="B", ttl_ms=30000))
    cc = out(c.semaphore_acquire(S, limit=3, holder="C", ttl_ms=30000))
    check("C permit 3/3 (available 0)", cc.get("acquired") is True and cc.get("available") == 0, cc)
    d = out(c.semaphore_acquire(S, limit=3, holder="D", wait=False))
    check("D blocked at cap", d.get("acquired") is False, d)

    snap = c.semaphore_get(S)["semaphore"]
    check("inspect: limit 3, 3 holders, 0 free", snap.get("limit") == 3
          and len(snap.get("holders", [])) == 3 and snap.get("available") == 0, snap)

    out(c.semaphore_release(S, "A", a["fencing_token"]))
    d2 = out(c.semaphore_acquire(S, limit=3, holder="D", ttl_ms=30000))
    check("D acquires after a release", d2.get("acquired") is True, d2)


def t_semaphore_as_mutex():
    section("semaphore limit=1 behaves as a mutex")
    S = key("sem1")
    a = out(c.semaphore_acquire(S, limit=1, holder="A", ttl_ms=30000))
    check("first permit acquired", a.get("acquired") is True, a)
    b = out(c.semaphore_acquire(S, limit=1, holder="B", wait=False))
    check("second blocked (limit 1)", b.get("acquired") is False, b)
    out(c.semaphore_release(S, "A", a["fencing_token"]))


def _fire_together(n, fn):
    """Run fn(i) on n threads released simultaneously; collect results."""
    barrier = threading.Barrier(n)
    results = [None] * n
    def worker(i):
        cl = FiduciaClient(BASE, timeout=25)
        barrier.wait()
        results[i] = fn(cl, i)
    threads = [threading.Thread(target=worker, args=(i,)) for i in range(n)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return results


def t_contended_mutex():
    section("contention: N simultaneous acquires -> exactly ONE winner (Raft linearizes)")
    K = key("race")
    N = 12
    res = _fire_together(N, lambda cl, i: out(
        cl.lock_acquire(K, holder="w%d" % i, ttl_ms=15000, wait=False)))
    winners = [r for r in res if r.get("acquired") is True]
    check("exactly 1 of %d acquired the lock" % N, len(winners) == 1,
          "winners=%d" % len(winners))
    toks = {r["fencing_token"] for r in winners}
    check("winner has a unique fencing token", len(toks) == 1, toks)
    for w in winners:
        out(c.lock_release(w["holder"], w["fencing_token"]))


def t_contended_semaphore():
    section("contention: N simultaneous semaphore acquires -> exactly LIMIT winners")
    S = key("semrace")
    N, L = 16, 4
    res = _fire_together(N, lambda cl, i: out(
        cl.semaphore_acquire(S, limit=L, holder="w%d" % i, ttl_ms=15000, wait=False)))
    winners = [r for r in res if r.get("acquired") is True]
    check("exactly %d of %d got a permit" % (L, N), len(winners) == L,
          "winners=%d" % len(winners))
    snap = c.semaphore_get(S)["semaphore"]
    check("server agrees: %d holders, 0 free" % L,
          len(snap.get("holders", [])) == L and snap.get("available") == 0, snap)
    for w in winners:
        out(c.semaphore_release(S, w["holder"], w["fencing_token"]))


def main():
    print("fiducia live tests via Python SDK -> %s (run %s)" % (BASE, RUN))
    for t in (t_cluster_up, t_basic_mutex, t_release_errors, t_multikey_union,
              t_fifo_fairness, t_semaphore_cap, t_semaphore_as_mutex,
              t_contended_mutex, t_contended_semaphore):
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
