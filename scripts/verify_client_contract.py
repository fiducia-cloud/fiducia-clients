#!/usr/bin/env python3
"""Fail closed when any client language drifts from the JSON-Schema API contract."""

from __future__ import annotations

import hashlib
import json
import sys
import tomllib
from pathlib import Path
from typing import Any

try:
    from jsonschema import Draft202012Validator
    from jsonschema.exceptions import SchemaError
except ImportError as exc:  # pragma: no cover - exercised by dependency bootstrap.
    raise SystemExit(
        "client-contract: install the pinned jsonschema test dependency before validation"
    ) from exc

ROOT = Path(__file__).resolve().parents[1]
CLIENTS = ROOT / "clients"
SCHEMA = CLIENTS / "client-api.schema.json"
SURFACE = CLIENTS / "api-surface.json"
MANIFEST = CLIENTS / "contract-manifest.json"
FINGERPRINT = CLIENTS / ".api-surface.sha256"
ZPKG = ROOT / ".zpkg.toml"
MINIMUM_TARGETS = 15
SOURCE_SUFFIXES = {
    ".c",
    ".cc",
    ".cpp",
    ".cs",
    ".dart",
    ".erl",
    ".ex",
    ".exs",
    ".gleam",
    ".go",
    ".h",
    ".hpp",
    ".java",
    ".js",
    ".kt",
    ".kts",
    ".lua",
    ".mjs",
    ".ml",
    ".mli",
    ".php",
    ".py",
    ".rb",
    ".rs",
    ".scala",
    ".sh",
    ".swift",
    ".ts",
    ".zig",
}
METADATA_NAMES = {
    "CMakeLists.txt",
    "Cargo.toml",
    "Package.swift",
    "build.gradle",
    "build.gradle.kts",
    "build.zig",
    "composer.json",
    "deno.json",
    "dune",
    "gleam.toml",
    "go.mod",
    "mix.exs",
    "package.json",
    "pom.xml",
    "pubspec.yaml",
    "pyproject.toml",
    "rebar.config",
    "settings.gradle.kts",
}
METADATA_SUFFIXES = {".gemspec", ".opam"}
IGNORED_PARTS = {
    ".build",
    ".dart_tool",
    ".gradle",
    ".zed-contracts",
    "build",
    "dist",
    "node_modules",
    "target",
    "test",
    "tests",
}


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"missing {path.relative_to(ROOT)}")
    except json.JSONDecodeError as exc:
        fail(f"invalid JSON in {path.relative_to(ROOT)}: {exc}")


def fail(message: str) -> None:
    print(f"client-contract: {message}", file=sys.stderr)
    raise SystemExit(1)


def digest(value: Any) -> str:
    encoded = json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def resolve_inside(base: Path, relative: str, label: str) -> Path:
    candidate = (ROOT / relative).resolve()
    if not candidate.is_relative_to(base.resolve()):
        fail(f"{label} escapes {base.relative_to(ROOT)}: {relative!r}")
    return candidate


def marker_root(directory: Path, runtime: str) -> Path:
    direct = directory / ".zed-client-contract.json"
    if direct.is_file():
        return directory
    nested = directory / ".zed-contracts" / runtime
    if (nested / ".zed-client-contract.json").is_file():
        return nested
    return directory


def implementation_evidence(directory: Path) -> tuple[int, str]:
    records: list[dict[str, str]] = []
    for path in directory.rglob("*"):
        if (
            path.is_file()
            and not IGNORED_PARTS.intersection(path.relative_to(directory).parts)
            and (
                path.suffix.lower() in SOURCE_SUFFIXES
                or path.name in METADATA_NAMES
                or path.suffix.lower() in METADATA_SUFFIXES
            )
        ):
            records.append(
                {
                    "path": path.relative_to(directory).as_posix(),
                    "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                }
            )
    records.sort(key=lambda item: item["path"])
    return len(records), digest(records)


def main() -> None:
    schema = load_json(SCHEMA)
    surface = load_json(SURFACE)
    contract_manifest = load_json(MANIFEST)
    try:
        Draft202012Validator.check_schema(schema)
    except SchemaError as exc:
        fail(f"client-api.schema.json is not a valid Draft 2020-12 schema: {exc.message}")
    validation_errors = sorted(
        Draft202012Validator(schema).iter_errors(surface),
        key=lambda item: list(item.absolute_path),
    )
    if validation_errors:
        first = validation_errors[0]
        location = "/".join(map(str, first.absolute_path)) or "<root>"
        fail(f"api-surface schema error at {location}: {first.message}")

    surface_digest = digest(surface)
    if not FINGERPRINT.is_file() or FINGERPRINT.read_text(encoding="utf-8").strip() != surface_digest:
        fail("canonical API-surface fingerprint is missing or stale")
    if contract_manifest.get("apiSurfaceSha256") != surface_digest:
        fail("contract manifest does not reference the canonical API-surface fingerprint")

    package = surface.get("package", {})
    coordinate = package.get("coordinate")
    if contract_manifest.get("coordinate") != coordinate:
        fail("contract manifest package coordinate differs from api-surface.json")

    with ZPKG.open("rb") as handle:
        zpkg = tomllib.load(handle)
    dependency_table = zpkg.get("dependencies", {})
    interface_dependencies = {
        name: value if isinstance(value, str) else value.get("version")
        for name, value in dependency_table.items()
        if isinstance(name, str) and name.endswith("-interfaces")
    }
    interface_sources = package.get("interfaces", [])
    declared_interfaces = {
        item.get("coordinate"): item.get("versionRequirement")
        for item in interface_sources
        if isinstance(item, dict)
    }
    if not interface_dependencies or declared_interfaces != interface_dependencies:
        fail("api-surface interface sources must exactly match .zpkg.toml *-interfaces dependencies")
    if any(
        item.get("schemaDialect") != "https://json-schema.org/draft/2020-12/schema"
        for item in interface_sources
    ):
        fail("every interface source must declare JSON Schema Draft 2020-12")

    targets = contract_manifest.get("targets")
    if not isinstance(targets, list):
        fail("contract manifest targets must be an array")
    if contract_manifest.get("targetCount") != len(targets):
        fail("contract manifest targetCount does not match its targets array")
    if len(targets) < MINIMUM_TARGETS:
        fail(f"contract covers {len(targets)} targets; at least {MINIMUM_TARGETS} are required")

    seen_targets: set[str] = set()
    declared_dirs: list[Path] = []
    for entry in targets:
        if not isinstance(entry, dict):
            fail("contract manifest target entries must be objects")
        target = entry.get("target")
        runtime = entry.get("runtime")
        relative = entry.get("dir")
        if not all(isinstance(value, str) and value for value in (target, runtime, relative)):
            fail("contract manifest target entries require non-empty target, runtime, and dir")
        if target in seen_targets:
            fail(f"duplicate contract target: {target}")
        seen_targets.add(target)
        directory = resolve_inside(CLIENTS, relative, f"target {target} directory")
        if not directory.is_dir():
            fail(f"target {target} directory is missing: {relative}")
        implementation_file_count, implementation_digest = implementation_evidence(directory)
        if not target.startswith("extension-") and implementation_file_count == 0:
            fail(f"target {target} has no implementation source under {relative}")
        if (
            entry.get("implementationFileCount") != implementation_file_count
            or entry.get("implementationSha256") != implementation_digest
        ):
            fail(f"target {target} implementation source or export metadata drifted")
        declared_dirs.append(directory)

        marker = marker_root(directory, runtime)
        contract = load_json(marker / ".zed-client-contract.json")
        expected = {
            "schemaVersion": surface.get("schemaVersion"),
            "coordinate": coordinate,
            "target": target,
            "zedTarget": entry.get("zedTarget"),
            "runtime": runtime,
            "apiSurface": "clients/api-surface.json",
            "apiSurfaceSha256": surface_digest,
            "schemaId": schema.get("$id"),
        }
        if contract != expected:
            fail(f"target {target} contract marker differs from the canonical declaration")
        marker_digest = marker / ".zed-api-surface.sha256"
        if not marker_digest.is_file() or marker_digest.read_text(encoding="utf-8").strip() != surface_digest:
            fail(f"target {target} API fingerprint is missing or stale")

    language_dirs = sorted(
        path
        for path in CLIENTS.iterdir()
        if path.is_dir() and not path.name.startswith(".")
    )
    uncovered = [
        path.name
        for path in language_dirs
        if not any(directory == path.resolve() or directory.is_relative_to(path.resolve()) for directory in declared_dirs)
    ]
    if uncovered:
        fail(f"client directories missing contract coverage: {', '.join(uncovered)}")
    print(
        f"client-contract: {coordinate} validates against Draft 2020-12; "
        f"{len(targets)} targets and {len(language_dirs)} client directories covered"
    )


if __name__ == "__main__":
    main()
