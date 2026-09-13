#!/usr/bin/env python3
"""
check_surface.py — enforce the exported-interface contract across every client.

Reads contract/surface.contract.json, validates it against the JSON Schema
meta-schema contract/surface.schema.json, then checks each clients/<lang>/
directory really exports every declared operation under that language's naming
convention.

Exit codes
    0   contract valid, all gate-tier languages conform
    1   one or more gate-tier violations (or an expired waiver)
    2   the contract document itself is invalid / usage error

Typical wiring
    tests:        python3 contract/bin/check_surface.py
    pre-publish:  python3 contract/bin/check_surface.py --prepublish --lang ts
    CI:           python3 contract/bin/check_surface.py --format github
"""

import argparse
import datetime
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import extract  # noqa: E402

CONTRACT_DIR = os.path.dirname(HERE)
REPO_ROOT = os.path.dirname(CONTRACT_DIR)


# ---------------------------------------------------------------------------
# naming
# ---------------------------------------------------------------------------

_WORD_SPLIT = re.compile(r"[_\-\s]+")


def words(canonical):
    return [w for w in _WORD_SPLIT.split(canonical) if w]


def render(canonical, style):
    parts = words(canonical)
    if not parts:
        return canonical
    if style == "snake_case":
        return "_".join(p.lower() for p in parts)
    if style == "camelCase":
        return parts[0].lower() + "".join(p[:1].upper() + p[1:].lower() for p in parts[1:])
    if style == "PascalCase":
        return "".join(p[:1].upper() + p[1:].lower() for p in parts)
    if style == "kebab-case":
        return "-".join(p.lower() for p in parts)
    if style == "SCREAMING_SNAKE_CASE":
        return "_".join(p.upper() for p in parts)
    if style == "lowercase":
        return "".join(p.lower() for p in parts)
    return canonical


def acceptable_names(canonical, style):
    """Every spelling we will accept for a canonical operation name.

    Clients are allowed to be idiomatic, and idiom is not perfectly derivable:
    Ruby predicates take a `?`, Elixir bang-variants take a `!`, Swift and Dart
    frequently suffix `Async`, and several clients expose the same call as both
    `lock_acquire` and `lockAcquire`. Rather than fail honest clients, accept
    the small closed set of mechanical variants and let `aliases` in the
    contract carry anything genuinely unpredictable.
    """
    base = {
        render(canonical, style),
        render(canonical, "snake_case"),
        render(canonical, "camelCase"),
        render(canonical, "PascalCase"),
    }
    out = set()
    for name in base:
        out.add(name)
        out.add(name + "?")
        out.add(name + "!")
        out.add(name + "_async")
        out.add(name + "Async")
        out.add(name + "_sync")
    return out


def candidate_set(op, lang_dir, style, lang_cfg):
    """Every spelling of `op` this language may legitimately use."""
    base = acceptable_names(op["name"], style)
    out = set(base)
    prefix = lang_cfg.get("symbolPrefix") or ""
    if prefix:
        for c in base:
            out.add(prefix + c)
            out.add(prefix + c[:1].upper() + c[1:])
    out.update(op.get("aliases", {}).get(lang_dir, []))
    return out


# ---------------------------------------------------------------------------
# contract loading + meta-validation
# ---------------------------------------------------------------------------


def load_json(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def validate_contract(contract, schema):
    """Validate with the real `jsonschema` package when present, else the
    bundled subset validator. Returns a list of human-readable strings."""
    try:
        import warnings

        import jsonschema  # type: ignore

        with warnings.catch_warnings():
            warnings.simplefilter("ignore", DeprecationWarning)
            validator_cls = jsonschema.validators.validator_for(schema)
        validator_cls.check_schema(schema)
        validator = validator_cls(schema)
        return [
            "%s: %s" % ("/".join(str(p) for p in err.absolute_path) or "<root>", err.message)
            for err in sorted(validator.iter_errors(contract), key=lambda e: list(e.absolute_path))
        ]
    except ImportError:
        import jsonschema_mini

        v = jsonschema_mini.Validator(schema)
        errs = [str(e) for e in v.iter_errors(contract)]
        for kw in sorted(v.unknown_keywords):
            errs.append("<meta>: meta-schema uses keyword %r that the bundled validator "
                        "does not implement; install `jsonschema` or extend jsonschema_mini.py" % kw)
        return errs


# ---------------------------------------------------------------------------
# checking
# ---------------------------------------------------------------------------


class Finding(object):
    def __init__(self, severity, language, operation, message, path=None):
        self.severity = severity  # "error" | "warning" | "notice"
        self.language = language
        self.operation = operation
        self.message = message
        self.path = path

    def as_dict(self):
        return {
            "severity": self.severity,
            "language": self.language,
            "operation": self.operation,
            "message": self.message,
            "path": self.path,
        }


def _parse_date(value):
    try:
        y, m, d = (int(x) for x in value.split("-"))
        return datetime.date(y, m, d)
    except Exception:
        return None


def partition_waivers(contract, today):
    usable = {}
    expired = []
    for w in contract.get("waivers", []):
        exp = _parse_date(w.get("expires", ""))
        if exp is None or exp < today:
            expired.append(w)
            continue
        usable.setdefault(w["language"], set()).add(w["operation"])
    return usable, expired


def waived(usable, language, op_name):
    entries = usable.get(language, set())
    return "*" in entries or op_name in entries


def check_language(contract, lang_dir, lang_cfg, clients_root, usable_waivers):
    findings = []
    style = lang_cfg.get("naming") or contract["conventions"]["naming"].get("byLanguage", {}).get(
        lang_dir, contract["conventions"]["naming"]["default"]
    )
    client_path = os.path.join(clients_root, lang_dir)

    if not os.path.isdir(client_path):
        findings.append(Finding("error", lang_dir, None, "declared in the contract but clients/%s/ does not exist" % lang_dir))
        return findings, {}

    result = extract.extract(client_path, exclude=tuple(lang_cfg.get("exclude", [])))
    if result.get("unsupported") or not result["symbols"]:
        findings.append(
            Finding(
                "warning",
                lang_dir,
                None,
                "no exported symbols could be read (detected language: %s, files scanned: %d). "
                "Add `sources` to the contract's languages.%s entry if the surface lives somewhere unusual."
                % (result.get("language"), result.get("files", 0), lang_dir),
                path="clients/%s" % lang_dir,
            )
        )
        return findings, result

    present = result["symbols"]
    present_lower = {k.lower(): k for k in present}
    absent = []

    # 1. every declared operation must exist
    for op in contract["operations"]:
        name = op["name"]
        if lang_dir in op.get("optionalIn", []):
            continue
        if waived(usable_waivers, lang_dir, name):
            findings.append(Finding("notice", lang_dir, name, "skipped by an active waiver"))
            continue

        candidates = candidate_set(op, lang_dir, style, lang_cfg)
        hit = next((c for c in candidates if c in present), None)
        if hit is None:
            hit_ci = next((present_lower[c.lower()] for c in candidates if c.lower() in present_lower), None)
            if hit_ci is not None:
                findings.append(
                    Finding(
                        "warning",
                        lang_dir,
                        name,
                        "found only as %r, which differs from the %s convention (%r). "
                        "Rename it, or add it to aliases.%s in the contract."
                        % (hit_ci, style, render(name, style), lang_dir),
                        path="clients/%s" % lang_dir,
                    )
                )
                continue
            absent.append(name)
            findings.append(
                Finding(
                    "error",
                    lang_dir,
                    name,
                    "not exported. Expected %r (or one of: %s)."
                    % (render(name, style), ", ".join(sorted(candidates - {render(name, style)})[:4])),
                    path="clients/%s" % lang_dir,
                )
            )
            continue

        # 2. arity, where the language makes it statically legible
        if lang_cfg.get("enforceArity"):
            required = sum(1 for p in op.get("params", []) if p.get("required", True))
            actual = present[hit].get("arity")
            if actual is not None and actual < required:
                findings.append(
                    Finding(
                        "error",
                        lang_dir,
                        name,
                        "%r accepts %d parameter(s) but the contract declares %d required"
                        % (hit, actual, required),
                        path="clients/%s/%s" % (lang_dir, present[hit]["files"][0]),
                    )
                )

    # 2b. the ratchet: a partial client may stay partial, but may not regress
    required_ops = [o for o in contract["operations"]
                    if lang_dir not in o.get("optionalIn", [])
                    and not waived(usable_waivers, lang_dir, o["name"])]
    missing = len(absent)
    if required_ops:
        coverage = 100.0 * (len(required_ops) - min(missing, len(required_ops))) / len(required_ops)
        floor = lang_cfg.get("minCoverage")
        if floor is not None and coverage + 0.05 < floor:
            findings.append(
                Finding(
                    "error",
                    lang_dir,
                    None,
                    "coverage regressed to %.1f%% from the recorded floor of %.1f%% "
                    "(%d of %d declared operations missing). Restore the removed operations, or "
                    "lower languages.%s.minCoverage in the same PR with a reason."
                    % (coverage, floor, missing, len(required_ops), lang_dir),
                    path="clients/%s" % lang_dir,
                )
            )

    # 3. the primary client type must exist. Its spelling is per-language by
    #    nature (Go's package fiducia exposes `Client`, not `FiduciaClient`),
    #    so accept whatever type the client actually names as its client, and
    #    only insist on an exact match when the contract pins one.
    pinned = lang_cfg.get("clientType")
    actual_client = extract.find_client_type(client_path, result["language"], prefer=pinned)
    if actual_client is None:
        findings.append(
            Finding("warning", lang_dir, None,
                    "no client type found; expected a type whose name ends in 'Client'"
                    + (" (contract pins %r)" % pinned if pinned else ""),
                    path="clients/%s" % lang_dir))
    elif pinned and actual_client != pinned:
        findings.append(
            Finding("warning", lang_dir, None,
                    "client type is %r but the contract pins %r for this language"
                    % (actual_client, pinned),
                    path="clients/%s" % lang_dir))

    # 4. an error type must exist, under whatever name the language prefers.
    if contract["conventions"].get("errorTypes"):
        blob = _concat_sources(client_path, result["language"], lang_cfg)
        if not re.search(r"\b[A-Za-z_][A-Za-z0-9_]*(Error|Exception|Failure)\b", blob):
            findings.append(
                Finding("warning", lang_dir, None,
                        "no error type found; every client should surface failures as a named "
                        "type (contract declares %s)" % ", ".join(contract["conventions"]["errorTypes"]),
                        path="clients/%s" % lang_dir))

    # 5. optional: undeclared public operations
    if lang_cfg.get("forbidExtraPublic"):
        declared = set()
        for op in contract["operations"]:
            declared |= candidate_set(op, lang_dir, style, lang_cfg)
        for sym in sorted(present):
            if sym not in declared:
                findings.append(
                    Finding("error", lang_dir, sym, "public symbol is not declared in the contract", path="clients/%s" % lang_dir)
                )

    return findings, result


def _concat_sources(client_path, lang, lang_cfg, cap=2_000_000):
    chunks, total = [], 0
    if lang not in extract.LANGS:
        return ""
    for path in extract.iter_sources(client_path, lang, tuple(lang_cfg.get("exclude", []))):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                data = fh.read()
        except OSError:
            continue
        chunks.append(data)
        total += len(data)
        if total > cap:
            break
    return "\n".join(chunks)


# ---------------------------------------------------------------------------
# provenance
# ---------------------------------------------------------------------------


def check_provenance(contract, repo_root):
    """If the contract records the sha256 of its upstream source, verify it."""
    prov = contract.get("provenance") or {}
    src, want = prov.get("source"), prov.get("sourceSha256")
    if not src or not want:
        return []
    path = os.path.join(repo_root, src)
    if not os.path.exists(path):
        return [Finding("warning", None, None, "provenance source %s is missing; cannot verify drift" % src)]
    import hashlib

    got = hashlib.sha256(open(path, "rb").read()).hexdigest()
    if got != want:
        return [
            Finding(
                "error",
                None,
                None,
                "%s has changed since the contract was generated (sha256 %s != %s). "
                "Re-run contract/bin/derive_contract.py and review the diff." % (src, got[:12], want[:12]),
                path=src,
            )
        ]
    return []


def check_interface_schemas(contract, repo_root, schema_meta):
    """Verify the payload schemas vendored from the paired *-interfaces repo.

    Three questions, in order of how badly a "no" would hurt:
      1. is the vendored file still there and still parseable JSON?
      2. does it still hash to what the contract recorded (nobody hand-edited
         a vendored copy instead of changing the upstream)?
      3. if the interfaces repo happens to be checked out beside this one, has
         upstream moved on without us?
    """
    import hashlib

    findings = []
    entries = contract.get("interfaceSchemas") or []
    if not entries:
        return findings

    siblings = os.path.dirname(repo_root)
    for entry in entries:
        rel = entry["vendoredPath"]
        path = os.path.join(repo_root, rel)
        if not os.path.exists(path):
            findings.append(Finding("error", None, None, "vendored payload schema %s is missing" % rel, path=rel))
            continue
        raw = open(path, "rb").read()
        try:
            doc = json.loads(raw.decode("utf-8"))
        except ValueError as exc:
            findings.append(Finding("error", None, None, "%s is not valid JSON (%s)" % (rel, exc), path=rel))
            continue
        if not isinstance(doc, dict):
            findings.append(Finding("error", None, None, "%s is not a JSON Schema object" % rel, path=rel))
            continue

        got = hashlib.sha256(raw).hexdigest()
        if got != entry["sha256"]:
            findings.append(Finding(
                "error", None, None,
                "%s was edited in place (sha256 %s != recorded %s). Payload schemas are owned by %s — "
                "change it there and re-vendor, do not patch the copy."
                % (rel, got[:12], entry["sha256"][:12], entry.get("upstreamRepo", "the interfaces repo")),
                path=rel))
            continue

        upstream_repo, upstream_path = entry.get("upstreamRepo"), entry.get("upstreamPath")
        if upstream_repo and upstream_path:
            candidate = os.path.join(siblings, upstream_repo, upstream_path)
            if os.path.exists(candidate):
                up = hashlib.sha256(open(candidate, "rb").read()).hexdigest()
                if up != got:
                    findings.append(Finding(
                        "warning", None, None,
                        "%s has moved on in %s. Re-run derive_contract.py --interfaces-repo to re-vendor."
                        % (upstream_path, upstream_repo),
                        path=rel))
    return findings


# ---------------------------------------------------------------------------
# reporting
# ---------------------------------------------------------------------------


def report(findings, contract, tiers, fmt, out=sys.stdout):
    if fmt == "json":
        json.dump({"findings": [f.as_dict() for f in findings]}, out, indent=2)
        out.write("\n")
        return

    if fmt == "github":
        for f in findings:
            if f.severity == "notice":
                continue
            level = "error" if f.severity == "error" else "warning"
            props = ("file=%s" % f.path) if f.path else ""
            out.write("::%s %s::%s\n" % (level, props, _line(f).replace("\n", " ")))
        return

    by_lang = {}
    for f in findings:
        by_lang.setdefault(f.language, []).append(f)

    for lang in sorted(by_lang, key=lambda x: (x is None, x or "")):
        items = by_lang[lang]
        errs = sum(1 for f in items if f.severity == "error")
        warns = sum(1 for f in items if f.severity == "warning")
        if not errs and not warns:
            continue
        tier = tiers.get(lang, "-")
        header = "contract" if lang is None else "clients/%s" % lang
        out.write("\n%s  [tier=%s]  %d error(s), %d warning(s)\n" % (header, tier, errs, warns))
        for f in items:
            if f.severity == "notice":
                continue
            mark = "FAIL" if f.severity == "error" else "warn"
            out.write("  %-4s %s\n" % (mark, _line(f)))


def _line(f):
    if f.operation:
        return "%s: %s" % (f.operation, f.message)
    return f.message


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--contract", default=os.path.join(CONTRACT_DIR, "surface.contract.json"))
    ap.add_argument("--schema", default=os.path.join(CONTRACT_DIR, "surface.schema.json"))
    ap.add_argument("--clients-root", default=None, help="defaults to <repo>/clients")
    ap.add_argument("--lang", action="append", default=[], help="restrict to these clients/<dir> names")
    ap.add_argument("--prepublish", action="store_true",
                    help="pre-publish mode: warnings in the selected language become errors")
    ap.add_argument("--format", choices=["text", "json", "github"], default="text")
    ap.add_argument("--list-languages", action="store_true")
    ap.add_argument("--schema-only", action="store_true", help="validate the contract document and stop")
    args = ap.parse_args(argv)

    if not os.path.exists(args.contract):
        sys.stderr.write("surface contract not found: %s\n" % args.contract)
        return 2

    contract = load_json(args.contract)
    schema = load_json(args.schema)

    meta_errors = validate_contract(contract, schema)
    if meta_errors:
        sys.stderr.write("surface.contract.json does not satisfy surface.schema.json:\n")
        for e in meta_errors[:40]:
            sys.stderr.write("  - %s\n" % e)
        if len(meta_errors) > 40:
            sys.stderr.write("  ... and %d more\n" % (len(meta_errors) - 40))
        return 2

    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(args.contract)))
    clients_root = args.clients_root or os.path.join(repo_root, "clients")

    if args.list_languages:
        for name, cfg in sorted(contract["languages"].items()):
            print("%-20s tier=%s" % (name, cfg["tier"]))
        return 0

    if args.schema_only:
        extra = check_interface_schemas(contract, repo_root, schema)
        for f in extra:
            sys.stderr.write("  %s %s\n" % ("FAIL" if f.severity == "error" else "warn", f.message))
        print("contract OK: %d operations, %d languages, %d vendored payload schema(s), contractVersion %s"
              % (len(contract["operations"]), len(contract["languages"]),
                 len(contract.get("interfaceSchemas") or []), contract["contractVersion"]))
        return 1 if any(f.severity == "error" for f in extra) else 0

    today = datetime.date.today()
    usable_waivers, expired = partition_waivers(contract, today)

    findings = list(check_provenance(contract, repo_root))
    findings += check_interface_schemas(contract, repo_root, schema)
    for w in expired:
        findings.append(
            Finding(
                "error",
                w.get("language"),
                w.get("operation"),
                "waiver expired on %s (%s). Renew it with a fresh review or implement the operation."
                % (w.get("expires"), w.get("reason", "no reason recorded")),
            )
        )

    tiers = {name: cfg["tier"] for name, cfg in contract["languages"].items()}
    selected = args.lang or sorted(contract["languages"])

    checked = 0
    for lang_dir in selected:
        cfg = contract["languages"].get(lang_dir)
        if cfg is None:
            findings.append(Finding("error", lang_dir, None, "not declared in the contract's languages map"))
            continue
        if cfg["tier"] == "off":
            continue
        checked += 1
        lang_findings, _ = check_language(contract, lang_dir, cfg, clients_root, usable_waivers)
        findings.extend(lang_findings)

    # Tier policy: only `gate` languages can fail the build...
    fatal = 0
    for f in findings:
        if f.severity != "error":
            continue
        if f.language is None or tiers.get(f.language) == "gate":
            fatal += 1
        elif "coverage regressed" in f.message or "waiver expired" in f.message:
            # The ratchet and waiver expiry bind at every tier: `warn` means
            # "this client is allowed to be incomplete", not "anything goes".
            fatal += 1
    # ...except in pre-publish mode, where the artifact about to ship must be
    # clean regardless of tier, warnings included.
    if args.prepublish:
        fatal = sum(1 for f in findings if f.severity in ("error", "warning"))

    report(findings, contract, tiers, args.format)

    total_errors = sum(1 for f in findings if f.severity == "error")
    total_warnings = sum(1 for f in findings if f.severity == "warning")
    if args.format == "text":
        print(
            "\nsurface contract v%s — %d operations x %d language(s) checked: %d error(s), %d warning(s)%s"
            % (
                contract["contractVersion"],
                len(contract["operations"]),
                checked,
                total_errors,
                total_warnings,
                "  [prepublish]" if args.prepublish else "",
            )
        )
    return 1 if fatal else 0


if __name__ == "__main__":
    sys.exit(main())
