#!/usr/bin/env python3
"""fiducia — a coordination CLI for locks, semaphores, KV, elections, service
discovery, rate limiting and cron. It drives the Python SDK (FiduciaClient), so
the wire protocol stays encapsulated in the library — the CLI never speaks HTTP.

    export FIDUCIA_URL=http://<lb-host>:8088
    fiducia status
    fiducia lock acquire --keys orders/42,inventory/9 --holder worker-a --ttl-ms 30000
    fiducia lock release --holder worker-a --token 7
    fiducia kv put --key flags/checkout --value on
    fiducia sem acquire --key pools/db --limit 5 --holder w1
    fiducia election campaign --name scheduler --candidate node-a --ttl-ms 30000
    fiducia service register --service api --id i-1 --address http://10.0.0.1:8080 --ttl-ms 30000
    fiducia ratelimit check --tenant acme --key checkout --algorithm token_bucket --limit 100 --window-ms 60000
    fiducia cron upsert --name nightly --cron '0 0 * * *' --webhook https://x/y
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fiducia import FiduciaClient, FiduciaError  # noqa: E402


def _emit(v):
    print(json.dumps(v, indent=2, sort_keys=True))


def _csv(s):
    return [p for p in (s or "").split(",") if p]


def build_parser():
    p = argparse.ArgumentParser(prog="fiducia", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--url", default=os.environ.get("FIDUCIA_URL", "http://127.0.0.1:8088"),
                   help="LB base URL (or $FIDUCIA_URL)")
    sub = p.add_subparsers(dest="group", required=True)

    sub.add_parser("status")
    sub.add_parser("health")

    lk = sub.add_parser("lock").add_subparsers(dest="action", required=True)
    a = lk.add_parser("acquire")
    a.add_argument("--keys", required=True, help="comma-separated (UNION lock if >1)")
    a.add_argument("--holder", required=True)
    a.add_argument("--ttl-ms", type=int)
    a.add_argument("--wait", action="store_true")
    r = lk.add_parser("release"); r.add_argument("--holder", required=True); r.add_argument("--token", type=int, required=True)
    g = lk.add_parser("get"); g.add_argument("--key", required=True)

    sm = sub.add_parser("sem").add_subparsers(dest="action", required=True)
    a = sm.add_parser("acquire")
    a.add_argument("--key", required=True); a.add_argument("--limit", type=int, required=True)
    a.add_argument("--holder", required=True); a.add_argument("--ttl-ms", type=int); a.add_argument("--wait", action="store_true")
    r = sm.add_parser("release"); r.add_argument("--key", required=True); r.add_argument("--holder", required=True); r.add_argument("--token", type=int, required=True)
    g = sm.add_parser("get"); g.add_argument("--key", required=True)

    kv = sub.add_parser("kv").add_subparsers(dest="action", required=True)
    pu = kv.add_parser("put"); pu.add_argument("--key", required=True); pu.add_argument("--value", required=True)
    pu.add_argument("--ttl-ms", type=int); pu.add_argument("--prev-revision", type=int)
    pu.add_argument("--plaintext", action="store_true", default=None,
                    help="explicitly opt this value out of at-rest encryption")
    g = kv.add_parser("get"); g.add_argument("--key", required=True)
    d = kv.add_parser("delete"); d.add_argument("--key", required=True)

    el = sub.add_parser("election").add_subparsers(dest="action", required=True)
    cmp = el.add_parser("campaign"); cmp.add_argument("--name", required=True); cmp.add_argument("--candidate", required=True); cmp.add_argument("--ttl-ms", type=int, required=True)
    rn = el.add_parser("renew"); rn.add_argument("--name", required=True); rn.add_argument("--candidate", required=True); rn.add_argument("--token", type=int, required=True)
    rs = el.add_parser("resign"); rs.add_argument("--name", required=True); rs.add_argument("--candidate", required=True); rs.add_argument("--token", type=int, required=True)
    ob = el.add_parser("observe"); ob.add_argument("--name", required=True)

    sv = sub.add_parser("service").add_subparsers(dest="action", required=True)
    rg = sv.add_parser("register"); rg.add_argument("--service", required=True); rg.add_argument("--id", required=True)
    rg.add_argument("--address", required=True); rg.add_argument("--ttl-ms", type=int, required=True); rg.add_argument("--meta", help="k=v,k=v")
    hb = sv.add_parser("heartbeat"); hb.add_argument("--service", required=True); hb.add_argument("--id", required=True)
    dr = sv.add_parser("deregister"); dr.add_argument("--service", required=True); dr.add_argument("--id", required=True)
    ls = sv.add_parser("list"); ls.add_argument("--service", required=True)

    rl = sub.add_parser("ratelimit").add_subparsers(dest="action", required=True)
    ck = rl.add_parser("check")
    ck.add_argument("--tenant", required=True); ck.add_argument("--key", required=True)
    ck.add_argument("--algorithm", default="token_bucket", choices=["token_bucket", "sliding_window"])
    ck.add_argument("--limit", type=int, required=True); ck.add_argument("--window-ms", type=int, required=True)
    ck.add_argument("--refill-per-second", type=float); ck.add_argument("--cost", type=int)
    gl = rl.add_parser("get"); gl.add_argument("--tenant", required=True); gl.add_argument("--key", required=True)

    cr = sub.add_parser("cron").add_subparsers(dest="action", required=True)
    up = cr.add_parser("upsert"); up.add_argument("--name", required=True)
    up.add_argument("--cron"); up.add_argument("--one-shot-at-ms", type=int)
    up.add_argument("--webhook"); up.add_argument("--queue"); up.add_argument("--grpc")
    up.add_argument("--delivery", choices=["at_least_once", "exactly_once"]); up.add_argument("--max-retries", type=int)
    g = cr.add_parser("get"); g.add_argument("--name", required=True)
    rr = cr.add_parser("run"); rr.add_argument("--name", required=True); rr.add_argument("--fire-id", required=True)
    h = cr.add_parser("history"); h.add_argument("--name", required=True)
    return p


def run(args, c):
    g, act = args.group, getattr(args, "action", None)
    if g == "status":
        return c.status()
    if g == "health":
        return c.health()
    if g == "lock":
        if act == "acquire":
            return c.lock_acquire_many(_csv(args.keys), holder=args.holder, ttl_ms=args.ttl_ms, wait=args.wait)
        if act == "release":
            return c.lock_release(args.holder, args.token)
        if act == "get":
            return c.lock_get(args.key)
    if g == "sem":
        if act == "acquire":
            return c.semaphore_acquire(args.key, args.limit, holder=args.holder, ttl_ms=args.ttl_ms, wait=args.wait)
        if act == "release":
            return c.semaphore_release(args.key, args.holder, args.token)
        if act == "get":
            return c.semaphore_get(args.key)
    if g == "kv":
        if act == "put":
            return c.kv_put(args.key, args.value, ttl_ms=args.ttl_ms,
                            prev_revision=args.prev_revision, plaintext=args.plaintext)
        if act == "get":
            return c.kv_get(args.key)
        if act == "delete":
            return c.kv_delete(args.key)
    if g == "election":
        if act == "campaign":
            return c.election_campaign(args.name, args.candidate, args.ttl_ms)
        if act == "renew":
            return c.election_renew(args.name, args.candidate, args.token)
        if act == "resign":
            return c.election_resign(args.name, args.candidate, args.token)
        if act == "observe":
            return c.election_get(args.name)
    if g == "service":
        if act == "register":
            meta = dict(kv.split("=", 1) for kv in _csv(args.meta)) if args.meta else None
            return c.service_register(args.service, args.id, args.address, args.ttl_ms, metadata=meta)
        if act == "heartbeat":
            return c.service_heartbeat(args.service, args.id)
        if act == "deregister":
            return c.service_deregister(args.service, args.id)
        if act == "list":
            return c.service_instances(args.service)
    if g == "ratelimit":
        if act == "check":
            return c.rate_limit_check(args.tenant, args.key, args.algorithm, args.limit,
                                      args.window_ms, refill_per_second=args.refill_per_second, cost=args.cost)
        if act == "get":
            return c.rate_limit_get(args.tenant, args.key)
    if g == "cron":
        if act == "upsert":
            target = ({"kind": "webhook", "url": args.webhook} if args.webhook else
                      {"kind": "queue", "name": args.queue} if args.queue else
                      {"kind": "grpc", "endpoint": args.grpc} if args.grpc else None)
            if target is None:
                raise SystemExit("cron upsert needs --webhook/--queue/--grpc")
            return c.schedule_upsert(args.name, target, cron=args.cron, one_shot_at_ms=args.one_shot_at_ms,
                                     delivery=args.delivery, max_retries=args.max_retries)
        if act == "get":
            return c.schedule_get(args.name)
        if act == "run":
            return c.schedule_record_run(args.name, args.fire_id)
        if act == "history":
            return c.schedule_history(args.name)
    raise SystemExit("unknown command")


def main(argv=None, client_factory=FiduciaClient):
    # client_factory is injectable so the dispatch can be unit-tested offline.
    args = build_parser().parse_args(argv)
    c = client_factory(args.url)
    try:
        _emit(run(args, c))
        return 0
    except FiduciaError as e:
        _emit({"error": "http", "status": e.status, "body": e.body})
        return 1


if __name__ == "__main__":
    sys.exit(main())
