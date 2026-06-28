#!/usr/bin/env python3
"""Resilience / operational live tests for fiducia, per fiducia-infra/docs/ROLLOUT.md.

Two scenarios:
  * node-unresponsive  — SIGSTOP a node's server process so it goes silent WITHOUT
    being terminated; the cluster must keep serving on the surviving 2/3 quorum,
    re-elect a leader, never double-grant a lock, and the node must rejoin on
    resume. (Terminating an actual VM/pod is a separate, later test.)
  * rolling-restart    — roll a deployment/statefulset while a continuous lock
    workload runs; assert the ROLLOUT.md invariants hold (no split-brain, quorum
    visible, writes recover). Bounded so it can run without waiting out a full
    ~10-min-per-pod source rebuild.

Runs ON a cluster host (needs kubectl + KUBECONFIG); lock ops go through the SDK
against the LB:

    FIDUCIA_URL=http://<lb>:8088 FIDUCIA_NS=fiducia python3 resilience_tests.py node
    FIDUCIA_URL=http://<lb>:8088 python3 resilience_tests.py rollout statefulset/fiducia-node
"""
import json
import os
import subprocess
import sys
import threading
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fiducia import FiduciaClient  # noqa: E402

NS = os.environ.get("FIDUCIA_NS", "fiducia")
BASE = os.environ.get("FIDUCIA_URL", "http://127.0.0.1:8088")
NODES = ["fiducia-node-0", "fiducia-node-1", "fiducia-node-2"]
_P = {"pass": 0, "fail": 0, "failed": []}


def check(name, cond, detail=""):
    if cond:
        _P["pass"] += 1
        print("  ok   %s" % name)
    else:
        _P["fail"] += 1
        _P["failed"].append(name)
        print("  FAIL %s   %s" % (name, detail))


def kubectl(*args, timeout=30):
    return subprocess.run(["kubectl", "-n", NS, *args],
                          capture_output=True, text=True, timeout=timeout)


def pod_ip(pod):
    return kubectl("get", "pod", pod, "-o", "jsonpath={.status.podIP}").stdout.strip()


def node_shard0(pod, ip=None):
    """(role, term) from a node's own /v1/status, or None if unresponsive."""
    ip = ip or pod_ip(pod)
    if not ip:
        return None
    try:
        with urllib.request.urlopen("http://%s:8090/v1/status" % ip, timeout=4) as r:
            d = json.load(r)["consensus"]["shards"][0]
            return d["role"], d["term"]
    except Exception:
        return None


def find_leader():
    for p in NODES:
        r = node_shard0(p)
        if r and r[0] == "leader":
            return p
    return None


# SIGSTOP/SIGCONT the server child by its comm — pure /proc, no procps needed,
# same-uid signal (the exec runs as the container user, like the server).
_FIND = ('for p in /proc/[0-9]*; do [ "$(cat $p/comm 2>/dev/null)" = fiducia-node ] '
         '&& echo "${p#/proc/}" && break; done')


def signal_server(pod, sig):
    out = kubectl("exec", pod, "--", "bash", "-c",
                  'pid=$(%s); [ -n "$pid" ] && kill -%s "$pid" && echo "$pid"' % (_FIND, sig))
    return out.stdout.strip()


class Workload:
    """Background workers hammering one lock key via the LB. Records throughput
    and — the key safety invariant — any moment two holders exist at once."""

    def __init__(self, key, workers=4, ttl_ms=4000):
        self.key, self.workers, self.ttl_ms = key, workers, ttl_ms
        self.ok = self.fail = self.violations = 0
        self._held = set()
        self._lock = threading.Lock()
        self._stop = False
        self._threads = []

    def _run(self, holder):
        cl = FiduciaClient(BASE, timeout=6)
        while not self._stop:
            try:
                out = cl.lock_acquire(self.key, holder=holder, ttl_ms=self.ttl_ms,
                                      wait=False)["result"]["output"]
                if out.get("acquired"):
                    with self._lock:
                        if self._held:
                            self.violations += 1
                        self._held.add(holder)
                    time.sleep(0.02)
                    with self._lock:
                        self._held.discard(holder)
                    cl.lock_release(holder, out["fencing_token"])
                with self._lock:
                    self.ok += 1
            except Exception:
                with self._lock:
                    self.fail += 1
            time.sleep(0.01)

    def start(self):
        self._threads = [threading.Thread(target=self._run, args=("w%d" % i,), daemon=True)
                         for i in range(self.workers)]
        for t in self._threads:
            t.start()

    def stop(self):
        self._stop = True
        for t in self._threads:
            t.join(timeout=5)

    def snapshot(self):
        with self._lock:
            return self.ok, self.fail, self.violations


def lock_write_succeeds(timeout=20):
    """Can we acquire+release a fresh lock through the LB within `timeout`?"""
    cl = FiduciaClient(BASE, timeout=6)
    key = "resil/probe/%d" % time.time_ns()
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            out = cl.lock_acquire(key, holder="probe", ttl_ms=3000)["result"]["output"]
            if out.get("acquired"):
                cl.lock_release("probe", out["fencing_token"])
                return True
        except Exception:
            pass
        time.sleep(0.5)
    return False


# ---------------------------------------------------------------------------
def test_node_unresponsive():
    print("\n== node goes unresponsive (SIGSTOP) — quorum survives, no split-brain ==")
    leader = find_leader()
    check("found a current leader", leader is not None, "no leader visible")
    if not leader:
        return
    print("    current leader: %s" % leader)

    wl = Workload(key="resil/chaos/%d" % time.time_ns())
    wl.start()
    time.sleep(2)

    pid = signal_server(leader, "STOP")
    check("paused the leader's server process (SIGSTOP)", pid != "", "no pid found")
    print("    %s server pid %s STOPped — waiting for re-election..." % (leader, pid))
    try:
        # The frozen leader can't serve; the LB must fail over to the new leader.
        check("cluster still commits a lock write on 2/3 quorum",
              lock_write_succeeds(timeout=25), "no write committed while a node was down")

        survivors = [p for p in NODES if p != leader]
        new = None
        for _ in range(20):
            roles = {p: node_shard0(p) for p in survivors}
            leaders = [p for p, r in roles.items() if r and r[0] == "leader"]
            if len(leaders) == 1:
                new = leaders[0]
                break
            time.sleep(1)
        check("exactly one NEW leader elected among the survivors", new is not None,
              "survivors roles=%s" % {p: node_shard0(p) for p in survivors})
        check("the paused node is not serving as a second leader",
              node_shard0(leader) is None, "paused node still responded")
    finally:
        out = signal_server(leader, "CONT")
        print("    %s server CONT (resumed: pid %s)" % (leader, out))

    # Rejoin: the resumed node answers /v1/status again and converges to follower.
    rejoined = False
    for _ in range(30):
        r = node_shard0(leader)
        if r and r[0] in ("follower", "leader"):
            rejoined = True
            break
        time.sleep(1)
    check("resumed node rejoins the cluster", rejoined, "did not rejoin in 30s")

    wl.stop()
    ok, fail, viol = wl.snapshot()
    print("    workload: ok=%d fail=%d (transient during election ok)" % (ok, fail))
    check("NO split-brain (two holders never coexisted)", viol == 0, "violations=%d" % viol)
    check("workload made progress overall", ok > 0, "no successful ops")


def test_rolling_restart(target):
    print("\n== rolling restart of %s — invariants hold during the roll ==" % target)
    monitor_s = int(os.environ.get("RESIL_ROLLOUT_MONITOR_S", "90"))
    check("preflight: a leader exists", find_leader() is not None)

    wl = Workload(key="resil/roll/%d" % time.time_ns())
    wl.start()
    time.sleep(2)
    base_ok, _, _ = wl.snapshot()

    r = kubectl("rollout", "restart", target)
    check("triggered rollout restart", r.returncode == 0, r.stderr.strip())

    print("    monitoring invariants for %ds (full roll continues after; rebuilds are slow)..." % monitor_s)
    deadline = time.time() + monitor_s
    max_leaders = 0
    while time.time() < deadline:
        roles = [node_shard0(p) for p in NODES]
        leaders = sum(1 for r in roles if r and r[0] == "leader")
        max_leaders = max(max_leaders, leaders)
        time.sleep(2)

    # A write must still commit during the disruption (quorum held).
    check("a lock write still commits during the roll", lock_write_succeeds(timeout=25))
    check("never more than one leader at once (no split-brain during roll)",
          max_leaders <= 1, "saw %d simultaneous leaders" % max_leaders)

    wl.stop()
    ok, fail, viol = wl.snapshot()
    print("    workload during roll: ok=%d fail=%d" % (ok - base_ok, fail))
    check("NO split-brain during the roll", viol == 0, "violations=%d" % viol)
    check("workload kept making progress", ok > base_ok, "stalled")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "node"
    print("fiducia resilience tests -> %s (ns=%s)" % (BASE, NS))
    if cmd == "node":
        test_node_unresponsive()
    elif cmd == "rollout":
        test_rolling_restart(sys.argv[2] if len(sys.argv) > 2 else "statefulset/fiducia-node")
    else:
        print("usage: resilience_tests.py [node | rollout <target>]")
        sys.exit(2)
    print("\n==== %d passed, %d failed ====" % (_P["pass"], _P["fail"]))
    if _P["failed"]:
        print("failed: %s" % ", ".join(_P["failed"]))
        sys.exit(1)


if __name__ == "__main__":
    main()
