#!/usr/bin/env python3
"""End-to-end auth-chain test against a live cluster (run on a cluster host).

Proves: fiducia-auth mints real ES256 JWTs + publishes a JWKS, API keys live in
fiducia KV (introspected from there, never Supabase), and the LB verifies JWTs
OFFLINE + introspects API keys (cached) — accepting valid credentials and
rejecting bad ones even in permissive mode (absent creds are allowed; present-
but-invalid are rejected).

    LB_URL=http://<lb>:8088 AUTH_URL=http://<auth>:8097 \
    INTROSPECT_SECRET=<secret> python3 auth_e2e.py
"""
import base64
import hashlib
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

LB = os.environ["LB_URL"]
AUTH = os.environ["AUTH_URL"]
INTRO = os.environ.get("INTROSPECT_SECRET", "")
_P = {"pass": 0, "fail": 0}


def chk(name, cond, detail=""):
    if cond:
        _P["pass"] += 1
        print("  ok   %s" % name)
    else:
        _P["fail"] += 1
        print("  FAIL %s   %s" % (name, detail))


def req(url, method="GET", body=None, headers=None, timeout=8):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    if data is not None:
        r.add_header("content-type", "application/json")
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    except Exception as e:  # noqa: BLE001
        return 0, str(e)


def b64url(part):
    return base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))


def lb_lock(headers=None):
    ts = time.time_ns()
    s, _ = req(LB + "/v1/locks/acquire", "POST",
               {"keys": ["e2e/%d" % ts], "holder": "e2e", "ttl_ms": 3000}, headers)
    return s


def main():
    print("auth e2e -> LB=%s AUTH=%s" % (LB, AUTH))

    # 1. Auth liveness + a REAL published JWKS (not the old empty stub).
    s, _ = req(AUTH + "/healthz")
    chk("auth healthz", s == 200, s)
    s, b = req(AUTH + "/.well-known/jwks.json")
    keys = (json.loads(b).get("keys") if s == 200 else None) or []
    chk("auth publishes a real ES256 JWKS",
        s == 200 and len(keys) == 1 and keys[0].get("kty") == "EC"
        and keys[0].get("alg") == "ES256" and keys[0].get("x"), (s, b[:200]))

    # 2. Seed an API key directly into fiducia KV (the durable store), then prove
    #    auth introspects it from there.
    key_id = secrets.token_hex(8)
    secret = secrets.token_hex(32)
    raw = "fdc_live_%s.%s" % (key_id, secret)
    stored = {
        "key_id": key_id, "org_id": "org_e2e", "name": "e2e",
        "secret_hash": "sha256:" + hashlib.sha256(secret.encode()).hexdigest(),
        "scopes": ["locks:write", "kv:read"], "created_ms": int(time.time() * 1000),
        "last_used_ms": None, "revoked": False, "env": "live",
    }
    kv_url = LB + "/v1/kv?key=" + urllib.parse.quote("__auth/keys/" + key_id, safe="")
    s, b = req(kv_url, "PUT", {"value": json.dumps(stored)})
    chk("seed key record into fiducia KV", s == 200 and json.loads(b).get("committed") is True, (s, b[:200]))

    s, b = req(AUTH + "/v1/introspect", "POST", {"api_key": raw}, {"x-internal-secret": INTRO})
    intro = json.loads(b) if s == 200 else {}
    chk("auth introspects the KV-backed key -> valid",
        s == 200 and intro.get("valid") is True and intro.get("org_id") == "org_e2e", (s, b[:200]))
    chk("introspect requires the internal secret",
        req(AUTH + "/v1/introspect", "POST", {"api_key": raw})[0] == 401)

    # 3. Exchange the key for a short-lived JWT — real, not the stub.
    s, b = req(AUTH + "/v1/token", "POST", {"api_key": raw})
    jwt = (json.loads(b).get("token") if s == 200 else "") or ""
    chk("auth mints a real JWT (3-part, not stub)",
        s == 200 and jwt.count(".") == 2 and jwt != "stub.jwt.token", (s, b[:120]))
    payload = json.loads(b64url(jwt.split(".")[1])) if jwt.count(".") == 2 else {}
    chk("JWT carries org_id + future exp",
        payload.get("org_id") == "org_e2e" and payload.get("exp", 0) > time.time(), payload)

    # 4. LB enforcement (permissive: absent allowed, present-but-bad rejected).
    chk("LB allows anonymous (permissive default)", lb_lock() == 200)
    chk("LB accepts a valid fiducia JWT (verified offline vs JWKS)",
        lb_lock({"authorization": "Bearer %s" % jwt}) == 200)
    chk("LB rejects a garbage JWT (offline verify actually ran)",
        lb_lock({"authorization": "Bearer aaaa.bbbb.cccc"}) == 401)
    chk("LB accepts a valid API key (introspected + cached)",
        lb_lock({"authorization": "Bearer %s" % raw}) == 200)
    chk("LB rejects a bad API key", lb_lock({"authorization": "Bearer fdc_live_bad.bad"}) == 401)

    print("\n==== %d passed, %d failed ====" % (_P["pass"], _P["fail"]))
    sys.exit(1 if _P["fail"] else 0)


if __name__ == "__main__":
    main()
