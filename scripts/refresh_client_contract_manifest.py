#!/usr/bin/env python3
"""Recompute implementation evidence without changing the canonical API surface.

This helper writes a candidate contract manifest to a separate path. Reviewers can
inspect exact count and SHA-256 changes before replacing the committed evidence
manifest. It never changes api-surface.json, language markers, or public interfaces.
"""

from __future__ import annotations

import argparse
import hashlib
import json

import verify_client_contract as contract


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        default=".artifacts/client-contract/contract-manifest.refreshed.json",
        help="Candidate manifest path; must not equal clients/contract-manifest.json",
    )
    args = parser.parse_args()

    output = (contract.ROOT / args.output).resolve()
    if output == contract.MANIFEST.resolve():
        raise SystemExit("refusing to overwrite the committed contract manifest in place")
    if not output.is_relative_to(contract.ROOT.resolve()):
        raise SystemExit("output must stay inside the repository checkout")

    manifest = contract.load_json(contract.MANIFEST)
    targets = manifest.get("targets")
    if not isinstance(targets, list):
        raise SystemExit("contract manifest targets must be an array")

    changes: list[dict[str, object]] = []
    for entry in targets:
        if not isinstance(entry, dict):
            raise SystemExit("contract manifest target entries must be objects")
        target = entry.get("target")
        relative = entry.get("dir")
        if not isinstance(target, str) or not isinstance(relative, str):
            raise SystemExit("target entries require string target and dir values")
        directory = contract.resolve_inside(
            contract.CLIENTS, relative, f"target {target} directory"
        )
        count, digest = contract.implementation_evidence(directory)
        before_count = entry.get("implementationFileCount")
        before_digest = entry.get("implementationSha256")
        entry["implementationFileCount"] = count
        entry["implementationSha256"] = digest
        if before_count != count or before_digest != digest:
            changes.append(
                {
                    "target": target,
                    "dir": relative,
                    "beforeCount": before_count,
                    "afterCount": count,
                    "beforeSha256": before_digest,
                    "afterSha256": digest,
                }
            )

    manifest["targetCount"] = len(targets)
    output.parent.mkdir(parents=True, exist_ok=True)
    encoded = json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"
    output.write_text(encoded, encoding="utf-8")
    receipt = {
        "schema": "fiducia.client-contract-refresh/v1",
        "source": contract.MANIFEST.relative_to(contract.ROOT).as_posix(),
        "candidate": output.relative_to(contract.ROOT).as_posix(),
        "candidateSha256": hashlib.sha256(encoded.encode("utf-8")).hexdigest(),
        "changedTargetCount": len(changes),
        "changes": changes,
    }
    receipt_path = output.with_suffix(".receipt.json")
    receipt_path.write_text(
        json.dumps(receipt, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print(
        f"client-contract-refresh: wrote {output.relative_to(contract.ROOT)}; "
        f"{len(changes)} target evidence record(s) changed"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
