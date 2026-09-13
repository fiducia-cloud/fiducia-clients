#!/usr/bin/env python3
"""
derive_contract.py — bootstrap (or refresh) surface.contract.json.

Two sources, in order of preference:

  --from-operations PATH   The repo already has a machine-readable manifest
                           (operations.json). That manifest IS the contract;
                           this just re-expresses it in the schema-validated
                           form and records its sha256 so later drift is caught.

  --from-language DIR      No manifest exists. Take the most complete client as
                           the reference surface and lift its public operations
                           into a contract.

Tiers are then assigned by measurement, not by wishful thinking: a language is
promoted to `gate` only when it conforms today. Everything else lands at `warn`,
so the first commit is green and the real drift is visible rather than hidden
behind a fabricated waiver. Tightening a `warn` to a `gate` is then a deliberate,
reviewable one-line change.

Usage:
    derive_contract.py --repo . --product fiducia [--from-operations operations.json]
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import extract  # noqa: E402
import check_surface as cs  # noqa: E402

TYPE_MAP = {
    "string": "string", "str": "string", "text": "string",
    "int": "int", "integer": "int", "int64": "int", "number": "float",
    "float": "float", "double": "float",
    "bool": "bool", "boolean": "bool",
    "object": "object", "map": "object", "json": "object", "any": "any",
    "string[]": "string[]", "[]string": "string[]", "list[str]": "string[]",
    "int[]": "int[]", "object[]": "object[]",
}

PREFERRED_REFERENCE = ["python", "python3", "ts", "typescript", "go", "golang", "rust", "ruby", "java"]
DEFAULT_GATE_CANDIDATES = {"ts", "typescript", "python", "python3", "go", "golang", "rust"}

NOISE = {
    "new", "init", "initialize", "constructor", "main", "build", "clone", "close",
    "to_string", "tostring", "equals", "hash", "hash_code", "dispose", "drop",
    "from", "into", "default", "fmt", "display", "error", "with_options",
    "get", "set", "request", "send", "do", "run", "call", "exec",
}


def canonical(name):
    """Normalise any language's spelling of a symbol to snake_case."""
    name = name.rstrip("?!=")
    name = re.sub(r"(Async|_async)$", "", name)
    name = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", name)
    name = name.replace("-", "_").replace(".", "_")
    return re.sub(r"_+", "_", name).lower().strip("_")


def sha256(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def ops_from_manifest(manifest_path):
    data = json.load(open(manifest_path, "r", encoding="utf-8"))
    raw = data.get("operations") if isinstance(data, dict) else data
    if not isinstance(raw, list):
        raise SystemExit("%s has no top-level `operations` array" % manifest_path)

    out = []
    for entry in raw:
        if not isinstance(entry, dict) or "name" not in entry:
            continue
        op = {"name": canonical(entry["name"])}
        if entry.get("group"):
            op["group"] = re.sub(r"[^a-z0-9_-]", "-", str(entry["group"]).lower())
        if entry.get("doc"):
            op["doc"] = entry["doc"]
        method, path = entry.get("method"), entry.get("path")
        if method and path and str(path).startswith("/"):
            op["http"] = {"method": str(method).upper(), "path": path}
        params = []
        for p in entry.get("params", []) or []:
            if not isinstance(p, dict) or "name" not in p:
                continue
            pname = re.sub(r"[^a-z0-9_]", "_", canonical(p["name"]))
            if not re.match(r"^[a-z_]", pname):
                pname = "p_" + pname
            params.append({
                "name": pname,
                "in": p.get("in") if p.get("in") in ("path", "query", "body", "header", "option") else "body",
                "type": TYPE_MAP.get(str(p.get("type", "any")).lower(), "any"),
                "required": not p.get("optional", False),
            })
        op["params"] = params
        op["returns"] = {"type": "object"}
        out.append(op)

    # de-duplicate while keeping the richest definition of each name
    merged = {}
    for op in out:
        prev = merged.get(op["name"])
        if prev is None or len(op["params"]) > len(prev["params"]):
            merged[op["name"]] = op
    return [merged[k] for k in sorted(merged)]


def ops_from_language(client_dir):
    result = extract.extract(client_dir)
    ops = []
    for name, info in sorted(result["symbols"].items()):
        c = canonical(name)
        if not c or c in NOISE or len(c) < 3:
            continue
        arity = info.get("arity") or 0
        params = [{"name": "arg%d" % (i + 1), "in": "body", "type": "any", "required": True}
                  for i in range(min(arity, 6))]
        ops.append({"name": c, "params": params, "returns": {"type": "object"}})
    seen, uniq = set(), []
    for op in ops:
        if op["name"] in seen:
            continue
        seen.add(op["name"])
        uniq.append(op)
    return uniq



OPENAPI_TYPE = {
    "string": "string", "integer": "int", "number": "float",
    "boolean": "bool", "object": "object", "array": "any",
}


def _openapi_param_type(spec):
    schema = spec.get("schema") or {}
    t = schema.get("type")
    if t == "array":
        inner = (schema.get("items") or {}).get("type")
        return {"string": "string[]", "integer": "int[]", "object": "object[]"}.get(inner, "any")
    return OPENAPI_TYPE.get(t, "any")


def ops_from_openapi(path):
    """Lift operations out of an OpenAPI document.

    An operationId is the API's own name for the call, which makes it a far
    better contract identity than anything reverse-engineered from a client.
    """
    try:
        import yaml
    except ImportError:
        raise SystemExit(
            "reading %s needs PyYAML (pip install pyyaml). Note this is a "
            "maintainer-time dependency only: check_surface.py stays stdlib-only." % path
        )
    with open(path, "r", encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)

    methods = ("get", "post", "put", "patch", "delete", "head", "options")
    out = []
    for url, item in (doc.get("paths") or {}).items():
        if not isinstance(item, dict):
            continue
        shared = item.get("parameters") or []
        for method, op in item.items():
            if method not in methods or not isinstance(op, dict):
                continue
            op_id = op.get("operationId") or "%s_%s" % (method, re.sub(r"[^a-zA-Z0-9]+", "_", url).strip("_"))
            entry = {"name": canonical(op_id)}
            tags = op.get("tags") or []
            if tags:
                entry["group"] = re.sub(r"[^a-z0-9_-]+", "-", str(tags[0]).lower()).strip("-") or "misc"
            if op.get("summary") or op.get("description"):
                entry["doc"] = (op.get("summary") or op.get("description")).strip().splitlines()[0][:400]
            entry["http"] = {"method": method.upper(), "path": url}

            params = []
            for spec in list(shared) + list(op.get("parameters") or []):
                if not isinstance(spec, dict) or "name" not in spec:
                    continue
                loc = spec.get("in")
                params.append({
                    "name": canonical(spec["name"]) or "arg",
                    "in": loc if loc in ("path", "query", "header") else "query",
                    "type": _openapi_param_type(spec),
                    "required": bool(spec.get("required")) or loc == "path",
                })
            body = op.get("requestBody") or {}
            if body:
                params.append({
                    "name": "body",
                    "in": "body",
                    "type": "object",
                    "required": bool(body.get("required", True)),
                })
            entry["params"] = params
            entry["returns"] = {"type": "object"}
            out.append(entry)

    merged = {}
    for op in out:
        prev = merged.get(op["name"])
        if prev is None or len(op["params"]) > len(prev["params"]):
            merged[op["name"]] = op
    return [merged[k] for k in sorted(merged)]



def ops_from_api_surface(path):
    """Read the `api-surface.json` convention already used by some repos here.

    Those repos declare their surface as {"symbols": [...]} validated by a
    sibling `client-api.schema.json`. Rather than introducing a second,
    competing contract file, lift that declaration into this one and record its
    sha256, so the existing document stays the source of truth and this harness
    becomes the thing that actually enforces it against 20 languages of source.
    """
    with open(path, "r", encoding="utf-8") as fh:
        doc = json.load(fh)

    symbols = doc.get("symbols") or []
    ops, client_type = [], None

    def add(name, params, doc_text=None):
        c = canonical(name)
        if not c or c in NOISE:
            return
        entry = {"name": c, "params": [], "returns": {"type": "object"}}
        for i, prm in enumerate(params or []):
            pname = canonical(prm.get("name") or "arg%d" % (i + 1)) or "arg%d" % (i + 1)
            entry["params"].append({
                "name": pname,
                "in": "body",
                "type": TYPE_MAP.get(str(((prm.get("type") or {}).get("name")) or "any").lower(), "any"),
                "required": (prm.get("type") or {}).get("kind") != "optional" and not prm.get("optional"),
            })
        if doc_text:
            entry["doc"] = str(doc_text).strip().splitlines()[0][:400]
        ops.append(entry)

    for sym in symbols:
        name = sym.get("name") or ""
        if name.startswith("_"):
            continue
        definition = sym.get("definition") or {}
        kind = definition.get("kind") or sym.get("kind")
        if kind in ("class", "interface"):
            if kind == "class" and name.endswith("Client") and client_type is None:
                client_type = name
            for m in (definition.get("methods") or []):
                mname = m.get("name") or ""
                if mname.startswith("_") or m.get("visibility") == "private":
                    continue
                add(mname, m.get("parameters"), m.get("description"))
        elif kind == "function":
            add(name, definition.get("parameters") or sym.get("parameters"), sym.get("description"))

    merged = {}
    for op in ops:
        prev = merged.get(op["name"])
        if prev is None or len(op["params"]) > len(prev["params"]):
            merged[op["name"]] = op
    return [merged[k] for k in sorted(merged)], client_type


def vendor_interface_schemas(repo, interfaces_repo):
    """Copy the paired *-interfaces repo's JSON Schemas into contract/schemas/.

    Vendoring rather than cross-referencing keeps CI hermetic — a clients repo
    checkout has everything it needs — while the recorded sha256 means the copy
    still cannot silently diverge from the interfaces repo it came from.
    """
    import shutil

    if not interfaces_repo or not os.path.isdir(interfaces_repo):
        return []
    sources = []
    for sub in ("schema", "schemas"):
        d = os.path.join(interfaces_repo, sub)
        if os.path.isdir(d):
            for name in sorted(os.listdir(d)):
                # index.json is a manifest, and surface.schema.json is the
                # meta-schema this contract is written against, not a payload.
                if name.endswith(".json") and name not in ("index.json", "surface.schema.json"):
                    sources.append(os.path.join(d, name))
    if not sources:
        return []

    dest = os.path.join(repo, "contract", "schemas")
    os.makedirs(dest, exist_ok=True)
    entries = []
    for src in sources:
        base = os.path.basename(src)
        try:
            with open(src, "r", encoding="utf-8") as fh:
                doc = json.load(fh)
        except (OSError, ValueError):
            continue
        if not isinstance(doc, dict):
            continue
        shutil.copy2(src, os.path.join(dest, base))
        stem = re.sub(r"\.schema$", "", os.path.splitext(base)[0])
        type_name = "".join(w[:1].upper() + w[1:] for w in re.split(r"[-_.]+", stem) if w)
        if not re.match(r"^[A-Za-z_]", type_name):
            type_name = "T" + type_name
        entries.append({
            "name": type_name,
            "vendoredPath": "contract/schemas/%s" % base,
            "upstreamRepo": os.path.basename(os.path.normpath(interfaces_repo)),
            "upstreamPath": os.path.relpath(src, interfaces_repo),
            "sha256": sha256(src),
        })
    return entries



ENRICH_NOISE = NOISE | {
    "with_options", "with_request_id", "builder", "options", "config", "client",
    "new_client", "create", "create_client", "connect", "shutdown", "start", "stop",
    "serialize", "deserialize", "to_json", "from_json", "parse", "format", "validate",
    "encode", "decode", "read", "write", "next", "iter", "len", "size", "empty",
}


def enrich_from_clients(operations, clients_root, lang_dirs, product, threshold=0.6, min_langs=4):
    """Add operations that most clients already agree on.

    A contract lifted from a minimal declaration (an api-surface.json that names
    only `health`, say) enforces almost nothing, while the clients themselves
    have long since converged on a much larger common surface. Locking in that
    consensus is the point: it cannot break any client that already has the
    operation, and it stops the twentieth client from quietly omitting what the
    other nineteen provide.

    Only operations that a clear majority of clients already export are added, so
    this records agreement rather than inventing a wish list. The clients that
    lack one are not broken by its arrival: they sit at tier=warn behind their
    own coverage floor, and the gap becomes visible instead of invisible.
    """
    if len(lang_dirs) < min_langs:
        return operations, 0

    declared = {op["name"] for op in operations}
    tally, arity, active = {}, {}, []
    for d in lang_dirs:
        symbols = extract.extract(os.path.join(clients_root, d)).get("symbols", {})
        if not symbols:
            # A scaffolded directory with no exported symbols is not a dissenting
            # vote about the common surface; it just has not been written yet.
            continue
        active.append(d)
        seen = set()
        for sym, info in symbols.items():
            name = canonical(re.sub(r"^%s_?" % re.escape(product.lower().replace("-", "_")), "", canonical(sym)))
            if not name or len(name) < 4 or name in ENRICH_NOISE or name in declared:
                continue
            seen.add(name)
            if info.get("arity"):
                arity[name] = max(arity.get(name, 0), info["arity"])
        for name in seen:
            tally[name] = tally.get(name, 0) + 1

    if len(active) < min_langs:
        return operations, 0
    needed = max(min_langs, int(round(threshold * len(active))))
    added = []
    for name in sorted(tally):
        if tally[name] < needed:
            continue
        added.append({
            "name": name,
            "doc": "Common surface: exported by %d of the %d clients that had any surface "
                   "when the contract was adopted." % (tally[name], len(active)),
            "params": [],
            "returns": {"type": "object"},
        })
    return operations + added, len(added)


def pick_reference(clients_root):
    dirs = sorted(d for d in os.listdir(clients_root) if os.path.isdir(os.path.join(clients_root, d)))
    for pref in PREFERRED_REFERENCE:
        if pref in dirs:
            return pref
    best, best_n = None, -1
    for d in dirs:
        n = len(extract.extract(os.path.join(clients_root, d))["symbols"])
        if n > best_n:
            best, best_n = d, n
    return best


def naming_for(lang_dir):
    lang = extract.DIR_ALIASES.get(lang_dir.lower()) or lang_dir.lower()
    spec = extract.LANGS.get(lang)
    return spec["style"] if spec else "snake_case"



def detect_prefix(symbols, product):
    """Clients in languages without modules namespace every symbol by hand.
    Spot that convention rather than reporting 100% of the surface missing."""
    if not symbols:
        return None
    names = list(symbols)
    for cand in (product.lower() + "_", pascal(product) + "_", pascal(product), product.lower()):
        hits = sum(1 for n in names if n.startswith(cand))
        if hits >= 0.6 * len(names):
            return cand
    return None


def pascal(product):
    return "".join(p[:1].upper() + p[1:] for p in re.split(r"[-_\s]+", product) if p)


def build(repo, product, manifest, reference, gate_threshold, client_type=None,
          openapi=None, interfaces_repo=None, api_surface=None, enrich=False):
    clients_root = os.path.join(repo, "clients")
    lang_dirs = sorted(
        d for d in os.listdir(clients_root)
        if os.path.isdir(os.path.join(clients_root, d)) and not d.startswith(".")
    )

    if manifest:
        operations = ops_from_manifest(manifest)
        prov = {
            "source": os.path.relpath(manifest, repo),
            "sourceSha256": sha256(manifest),
            "sourceKind": "operations-manifest",
            "generatedBy": "contract/bin/derive_contract.py",
            "generatedAt": datetime.date.today().isoformat(),
        }
    elif api_surface:
        operations, detected = ops_from_api_surface(api_surface)
        client_type = client_type or detected
        prov = {
            "source": os.path.relpath(api_surface, repo),
            "sourceSha256": sha256(api_surface),
            "sourceKind": "api-surface",
            "generatedBy": "contract/bin/derive_contract.py --from-api-surface",
            "generatedAt": datetime.date.today().isoformat(),
        }
    elif openapi:
        operations = ops_from_openapi(openapi)
        prov = {
            "source": os.path.relpath(openapi, repo) if openapi.startswith(repo) else openapi,
            "sourceSha256": sha256(openapi),
            "sourceKind": "openapi",
            "canonicalRepo": os.path.basename(os.path.normpath(interfaces_repo)) if interfaces_repo else "",
            "generatedBy": "contract/bin/derive_contract.py --from-openapi",
            "generatedAt": datetime.date.today().isoformat(),
        }
        if not prov["canonicalRepo"]:
            del prov["canonicalRepo"]
    else:
        reference = reference or pick_reference(clients_root)
        operations = ops_from_language(os.path.join(clients_root, reference))
        prov = {
            "source": "clients/%s" % reference,
            "sourceKind": "reference-client",
            "generatedBy": "contract/bin/derive_contract.py --from-language %s" % reference,
            "generatedAt": datetime.date.today().isoformat(),
        }

    if enrich:
        lang_dirs_for_enrich = [d for d in lang_dirs if os.path.isdir(os.path.join(clients_root, d))]
        operations, added = enrich_from_clients(operations, clients_root, lang_dirs_for_enrich, product)
        if added:
            prov["enrichedFromClients"] = added

    if not operations:
        raise SystemExit("derived an empty operation set; refusing to write a vacuous contract")

    ctype = client_type
    if not ctype:
        want = pascal(product) + "Client"
        for probe in (reference or "", "ts", "typescript", "python", "python3", "go", "rust"):
            if not probe:
                continue
            found = extract.find_client_type(os.path.join(clients_root, probe), prefer=want) \
                if os.path.isdir(os.path.join(clients_root, probe)) else None
            if found:
                ctype = found
                break
    if not ctype or not re.match(r"^[A-Za-z_]\w*$", ctype):
        ctype = "".join(w[:1].upper() + w[1:] for w in re.split(r"[-_\s]+", product) if w) + "Client"
    if not re.match(r"^[A-Za-z_]", ctype):
        ctype = "Sdk" + ctype
    contract = {
        "$schema": "./surface.schema.json",
        "$comment": (
            "Declared exported interface for every client under clients/. Validated against "
            "surface.schema.json; enforced by contract/bin/check_surface.py in tests, in CI, and "
            "at pre-publish time. Edit this file to change the contract — never to paper over a "
            "client that drifted."
        ),
        "contractVersion": "1.0.0",
        "product": product,
        "provenance": prov,
        "conventions": {
            "clientType": ctype,
            "errorTypes": [re.sub(r"Client$", "", ctype) + "Error"],
            "naming": {
                "default": "snake_case",
                "byLanguage": {d: naming_for(d) for d in lang_dirs},
            },
        },
        "interfaceSchemas": [],
        "types": {},
        "operations": operations,
        "languages": {},
        "waivers": [],
    }

    vendored = vendor_interface_schemas(repo, interfaces_repo)
    if vendored:
        contract["interfaceSchemas"] = vendored
        contract["types"] = {
            e["name"]: {"$ref": "./schemas/%s" % os.path.basename(e["vendoredPath"])}
            for e in vendored
        }

    # Provisional: everything at warn so we can honestly measure where we are.
    for d in lang_dirs:
        cfg = {
            "tier": "warn",
            "naming": naming_for(d),
            "enforceArity": False,
            "exclude": [],
        }
        syms = extract.extract(os.path.join(clients_root, d)).get("symbols", {})
        prefix = detect_prefix(syms, product)
        if prefix:
            cfg["symbolPrefix"] = prefix
        # Pin the client type per language rather than assuming every language
        # spells it the same way; Go's package-scoped `Client` is not wrong.
        found = extract.find_client_type(os.path.join(clients_root, d), prefer=ctype)
        if found:
            cfg["clientType"] = found
        contract["languages"][d] = cfg

    # Measure, then promote only what actually conforms.
    stats = {}
    usable, _expired = cs.partition_waivers(contract, datetime.date.today())
    for d in lang_dirs:
        findings, _ = cs.check_language(contract, d, contract["languages"][d], clients_root, usable)
        errs = sum(1 for f in findings if f.severity == "error")
        total = len(operations)
        stats[d] = {"errors": errs, "conformance": round(100.0 * (total - min(errs, total)) / total, 1)}
        # Record today's coverage as the ratchet floor, rounded down so that
        # ordinary refactors never trip it but a deletion does.
        contract["languages"][d]["minCoverage"] = float(int(stats[d]["conformance"]))
        if errs == 0 and d in DEFAULT_GATE_CANDIDATES:
            contract["languages"][d]["tier"] = "gate"
        elif errs == 0 and stats[d]["conformance"] >= gate_threshold:
            contract["languages"][d]["tier"] = "gate"

    return contract, stats


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=".")
    ap.add_argument("--product", required=True)
    ap.add_argument("--from-operations", dest="manifest", default=None)
    ap.add_argument("--from-language", dest="reference", default=None)
    ap.add_argument("--from-api-surface", dest="api_surface", default=None,
                    help="an existing clients/api-surface.json declaration to build on")
    ap.add_argument("--from-openapi", dest="openapi", default=None,
                    help="OpenAPI document, usually in the paired *-interfaces repo")
    ap.add_argument("--interfaces-repo", dest="interfaces", default=None,
                    help="paired *-interfaces repo; its JSON Schemas are vendored into contract/schemas/")
    ap.add_argument("--client-type", default=None)
    ap.add_argument("--gate-threshold", type=float, default=100.0)
    ap.add_argument("--enrich-from-clients", dest="enrich", action="store_true",
                    help="also declare operations that at least 70%% of clients already export")
    ap.add_argument("--out", default=None)
    ap.add_argument("--stats", action="store_true")
    args = ap.parse_args(argv)

    repo = os.path.abspath(args.repo)
    manifest = os.path.join(repo, args.manifest) if args.manifest and not os.path.isabs(args.manifest) else args.manifest
    if manifest and not os.path.exists(manifest):
        manifest = None

    contract, stats = build(
        repo, args.product, manifest, args.reference, args.gate_threshold, args.client_type,
        openapi=os.path.abspath(args.openapi) if args.openapi else None,
        interfaces_repo=os.path.abspath(args.interfaces) if args.interfaces else None,
        api_surface=os.path.abspath(args.api_surface) if args.api_surface else None,
        enrich=args.enrich,
    )
    out = args.out or os.path.join(repo, "contract", "surface.contract.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(contract, fh, indent=2, sort_keys=False)
        fh.write("\n")

    gates = [d for d, c in contract["languages"].items() if c["tier"] == "gate"]
    print("wrote %s  (source: %s)" % (os.path.relpath(out, repo),
                                     contract.get("provenance", {}).get("sourceKind", "?")))
    if contract.get("provenance", {}).get("enrichedFromClients"):
        print("  enriched with %d operation(s) that most clients already agree on"
              % contract["provenance"]["enrichedFromClients"])
    if contract.get("interfaceSchemas"):
        print("  vendored %d payload schema(s) from %s"
              % (len(contract["interfaceSchemas"]),
                 contract["interfaceSchemas"][0].get("upstreamRepo", "the interfaces repo")))
    print("  operations: %d   languages: %d   gate: %d (%s)"
          % (len(contract["operations"]), len(contract["languages"]), len(gates), ", ".join(sorted(gates)) or "none"))
    if args.stats:
        for d in sorted(stats, key=lambda x: -stats[x]["conformance"]):
            print("  %-18s %5.1f%%  (%d missing)" % (d, stats[d]["conformance"], stats[d]["errors"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
