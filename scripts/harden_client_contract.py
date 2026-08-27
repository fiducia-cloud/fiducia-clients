#!/usr/bin/env python3
"""Harden a polyglot ``*-clients`` repository against the canonical Zed contract.

The script is intentionally deterministic and safe to run repeatedly.  It never
replaces existing product implementation files.  Missing runtime packages get a
small compileable baseline, while every runtime receives a content-addressed
contract marker derived from ``clients/api-surface.json``.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

import tomlkit
from jsonschema import Draft202012Validator

SCHEMA_VERSION = 1
MINIMUM_TARGETS = 15
VALID_ZED_TARGET_NAME = re.compile(r"^[a-z0-9][a-z0-9-]*[a-z0-9]$")
CONTRACT_SOURCE_SUFFIXES = {
    ".c", ".cc", ".cpp", ".cs", ".dart", ".erl", ".ex", ".exs",
    ".gleam", ".go", ".h", ".hpp", ".java", ".js", ".kt", ".kts",
    ".lua", ".mjs", ".ml", ".mli", ".php", ".py", ".rb", ".rs",
    ".scala", ".sh", ".swift", ".ts", ".zig",
}
CONTRACT_METADATA_NAMES = {
    "CMakeLists.txt", "Cargo.toml", "Package.swift", "build.gradle",
    "build.gradle.kts", "build.zig", "composer.json", "deno.json", "dune",
    "gleam.toml", "go.mod", "mix.exs", "package.json", "pom.xml",
    "pubspec.yaml", "pyproject.toml", "rebar.config", "settings.gradle.kts",
}
CONTRACT_METADATA_SUFFIXES = {".gemspec", ".opam"}
CONTRACT_IGNORED_PARTS = {
    ".build", ".dart_tool", ".gradle", ".zed-contracts", "build", "dist",
    "node_modules", "target", "test", "tests",
}


@dataclass(frozen=True)
class TargetSpec:
    name: str
    zed_target: str
    canonical_dir: str
    aliases: tuple[str, ...]
    adapter: str
    runtime: str | None = None
    zed_aliases: tuple[str, ...] = ()
    publish: bool = True


TARGETS: tuple[TargetSpec, ...] = (
    TargetSpec("c", "c", "clients/c", (), "none"),
    TargetSpec("cpp", "cpp", "clients/cpp", ("clients/cxx",), "none", zed_aliases=("cxx",)),
    TargetSpec("zig", "zig", "clients/zig", (), "none"),
    TargetSpec("wasm", "rust-wasm", "clients/wasm", (), "node"),
    TargetSpec(
        "gleamlang",
        "gleam",
        "clients/gleamlang",
        ("clients/gleam",),
        "none",
        zed_aliases=("gleamlang",),
    ),
    TargetSpec("erlang", "erlang", "clients/erlang", (), "none"),
    TargetSpec("elixir", "elixir", "clients/elixir", (), "none"),
    TargetSpec("dart", "dart", "clients/dart", (), "none"),
    TargetSpec("rust", "rust", "clients/rust", (), "none"),
    TargetSpec("java", "java", "clients/java", (), "java"),
    TargetSpec("golang", "golang", "clients/golang", ("clients/go",), "none", zed_aliases=("go",)),
    TargetSpec(
        "python3",
        "python",
        "clients/python3",
        ("clients/python",),
        "none",
        zed_aliases=("python3",),
    ),
    TargetSpec("ruby", "ruby", "clients/ruby", (), "none"),
    TargetSpec("php", "php", "clients/php", (), "none"),
    TargetSpec("kotlin", "kotlin", "clients/kotlin", (), "java"),
    TargetSpec("swift", "swift", "clients/swift", (), "none"),
    TargetSpec(
        "typescript-nodejs",
        "nodejs",
        "clients/typescript/nodejs",
        ("clients/typescript",),
        "node",
        "nodejs",
        ("typescript-nodejs", "typescript"),
    ),
    TargetSpec(
        "typescript-deno",
        "nodejs",
        "clients/typescript/deno",
        ("clients/typescript",),
        "none",
        "deno",
        ("typescript-deno", "deno"),
        False,
    ),
    TargetSpec(
        "typescript-bun",
        "nodejs",
        "clients/typescript/bun",
        ("clients/typescript",),
        "node",
        "bun",
        ("typescript-bun", "bun"),
        False,
    ),
    TargetSpec(
        "typescript-edge",
        "nodejs",
        "clients/typescript/edge",
        ("clients/typescript",),
        "none",
        "edge",
        ("typescript-edge", "edge"),
        False,
    ),
)


def clean(value: str) -> str:
    return value.strip() + "\n"


def snake(value: str) -> str:
    result = re.sub(r"[^A-Za-z0-9]+", "_", value).strip("_").lower() or "client"
    return f"z_{result}" if result[:1].isdigit() else result


def camel(value: str) -> str:
    parts = re.findall(r"[A-Za-z0-9]+", value)
    result = "".join(part[:1].upper() + part[1:] for part in parts) or "Client"
    return f"Z{result}" if result[:1].isdigit() else result


def kebab(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-") or "client"


def write_text(path: Path, content: str, changed: list[str], *, missing_only: bool = False) -> None:
    rendered = clean(content)
    if missing_only and path.exists():
        return
    previous = path.read_text(encoding="utf-8") if path.exists() else None
    if previous == rendered:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(rendered, encoding="utf-8")
    changed.append(path.as_posix())


def write_generated_text(
    path: Path,
    content: str,
    changed: list[str],
    *,
    previous_templates: tuple[str, ...] = (),
) -> None:
    """Create a scaffold or migrate only an exact older generated template.

    Hand-maintained runtime files remain untouched.  This gives the nightly
    hardener a narrow, reviewable migration path when a toolchain removes an API
    used by a template that earlier fleet runs may already have materialized.
    """

    if path.exists():
        previous = path.read_text(encoding="utf-8")
        allowed = {clean(template) for template in previous_templates}
        if previous != clean(content) and previous not in allowed:
            return
    write_text(path, content, changed)


def write_json(path: Path, value: Any, changed: list[str], *, missing_only: bool = False) -> None:
    write_text(
        path,
        json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False),
        changed,
        missing_only=missing_only,
    )


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def digest(value: Any) -> str:
    return hashlib.sha256(canonical_json(value)).hexdigest()


def primitive(name: str) -> dict[str, str]:
    return {"kind": "primitive", "name": name}


def named(name: str) -> dict[str, str]:
    return {"kind": "named", "name": name}


def optional(value: dict[str, Any]) -> dict[str, Any]:
    return {"kind": "optional", "item": value}


def baseline_symbols(cap: str) -> list[dict[str, Any]]:
    client = f"{cap}Client"
    options = f"{cap}ClientOptions"
    transport = f"{cap}Transport"
    request = f"_{cap}RequestContext"
    builder = f"_{cap}RequestBuilder"
    telemetry = f"_{cap}TelemetrySink"
    return [
        {
            "kind": "type",
            "name": options,
            "visibility": "public",
            "description": "Portable client construction options.",
            "definition": {
                "kind": "object",
                "fields": [
                    {
                        "name": "baseUrl",
                        "visibility": "public",
                        "type": primitive("string"),
                        "readonly": True,
                    },
                    {
                        "name": "bearerToken",
                        "visibility": "public",
                        "type": optional(primitive("string")),
                        "readonly": True,
                    },
                ],
            },
        },
        {
            "kind": "type",
            "name": request,
            "visibility": "private",
            "description": "Internal request correlation state.",
            "definition": {
                "kind": "object",
                "fields": [
                    {
                        "name": "requestId",
                        "visibility": "private",
                        "type": primitive("string"),
                        "readonly": True,
                    }
                ],
            },
        },
        {
            "kind": "interface",
            "name": transport,
            "visibility": "public",
            "description": "Transport abstraction implemented by runtime adapters.",
            "methods": [
                {
                    "name": "send",
                    "visibility": "public",
                    "parameters": [
                        {"name": "path", "type": primitive("string")},
                        {"name": "body", "type": optional(primitive("bytes"))},
                    ],
                    "returns": primitive("bytes"),
                    "async": True,
                    "static": False,
                    "throws": [named(f"{cap}ClientError")],
                }
            ],
        },
        {
            "kind": "interface",
            "name": telemetry,
            "visibility": "private",
            "description": "Internal telemetry sink.",
            "methods": [
                {
                    "name": "record",
                    "visibility": "private",
                    "parameters": [{"name": "event", "type": primitive("string")}],
                    "returns": primitive("void"),
                    "async": False,
                    "static": False,
                    "throws": [],
                }
            ],
        },
        {
            "kind": "type",
            "name": f"{cap}ClientError",
            "visibility": "public",
            "description": "Stable cross-runtime error categories.",
            "definition": {
                "kind": "enum",
                "values": ["InvalidConfiguration", "TransportFailure", "Unauthorized", "UnexpectedResponse"],
            },
        },
        {
            "kind": "class",
            "name": client,
            "visibility": "public",
            "description": "Standard public client entry point.",
            "fields": [
                {
                    "name": "options",
                    "visibility": "private",
                    "type": named(options),
                    "readonly": True,
                }
            ],
            "constructors": [
                {
                    "name": "new",
                    "visibility": "public",
                    "parameters": [{"name": "options", "type": named(options)}],
                    "returns": named(client),
                    "async": False,
                    "static": True,
                    "throws": [named(f"{cap}ClientError")],
                }
            ],
            "methods": [
                {
                    "name": "health",
                    "visibility": "public",
                    "parameters": [],
                    "returns": primitive("boolean"),
                    "async": True,
                    "static": False,
                    "throws": [named(f"{cap}ClientError")],
                },
                {
                    "name": "_request",
                    "visibility": "private",
                    "parameters": [
                        {"name": "path", "type": primitive("string")},
                        {"name": "context", "type": named(request)},
                    ],
                    "returns": primitive("bytes"),
                    "async": True,
                    "static": False,
                    "throws": [named(f"{cap}ClientError")],
                },
            ],
            "implements": [],
        },
        {
            "kind": "class",
            "name": builder,
            "visibility": "private",
            "description": "Internal request builder.",
            "fields": [],
            "constructors": [
                {
                    "name": "new",
                    "visibility": "private",
                    "parameters": [],
                    "returns": named(builder),
                    "async": False,
                    "static": True,
                    "throws": [],
                }
            ],
            "methods": [
                {
                    "name": "build",
                    "visibility": "private",
                    "parameters": [{"name": "path", "type": primitive("string")}],
                    "returns": primitive("bytes"),
                    "async": False,
                    "static": False,
                    "throws": [],
                }
            ],
            "implements": [],
        },
        {
            "kind": "function",
            "name": f"create{cap}Client",
            "visibility": "public",
            "description": "Construct the standard client entry point.",
            "parameters": [{"name": "options", "type": named(options)}],
            "returns": named(client),
            "async": False,
            "static": True,
            "throws": [named(f"{cap}ClientError")],
        },
        {
            "kind": "function",
            "name": f"_normalize{cap}BaseUrl",
            "visibility": "private",
            "description": "Normalize a base URL without network access.",
            "parameters": [{"name": "baseUrl", "type": primitive("string")}],
            "returns": primitive("string"),
            "async": False,
            "static": True,
            "throws": [named(f"{cap}ClientError")],
        },
    ]


def declared_interface_sources(root: Path) -> list[dict[str, str]]:
    """Read the canonical ``*-interfaces`` dependencies from .zpkg.toml."""

    manifest_path = root / ".zpkg.toml"
    if not manifest_path.is_file():
        return []
    manifest = tomllib.loads(manifest_path.read_text(encoding="utf-8"))
    dependencies = manifest.get("dependencies", {})
    if not isinstance(dependencies, dict):
        return []
    sources: list[dict[str, str]] = []
    for coordinate, requirement in sorted(dependencies.items()):
        if not isinstance(coordinate, str) or not coordinate.endswith("-interfaces"):
            continue
        if isinstance(requirement, str):
            version_requirement = requirement
        elif isinstance(requirement, dict) and isinstance(requirement.get("version"), str):
            version_requirement = requirement["version"]
        else:
            raise ValueError(f"interface dependency {coordinate!r} needs a string version requirement")
        sources.append(
            {
                "coordinate": coordinate,
                "versionRequirement": version_requirement,
                "schemaDialect": "https://json-schema.org/draft/2020-12/schema",
            }
        )
    return sources


def baseline_surface(
    org: str,
    repo: str,
    prefix: str,
    interfaces: list[dict[str, str]],
) -> dict[str, Any]:
    cap = camel(prefix)
    return {
        "$schema": "./client-api.schema.json",
        "schemaVersion": SCHEMA_VERSION,
        "package": {
            "coordinate": f"{org}/{repo}",
            "namespace": cap,
            "description": f"Canonical polyglot API contract for {org}/{repo}.",
            "interfaces": interfaces,
        },
        "symbols": baseline_symbols(cap),
    }


def merge_standard_symbols(surface: dict[str, Any], cap: str) -> bool:
    symbols = surface.setdefault("symbols", [])
    if not isinstance(symbols, list):
        raise ValueError("api-surface.json symbols must be an array")
    existing = {item.get("name") for item in symbols if isinstance(item, dict)}
    changed = False
    for symbol in baseline_symbols(cap):
        if symbol["name"] not in existing:
            symbols.append(symbol)
            existing.add(symbol["name"])
            changed = True
    return changed


def iter_type_refs(value: Any) -> Iterable[dict[str, Any]]:
    if isinstance(value, dict):
        if value.get("kind") in {"primitive", "named", "array", "optional", "map", "union", "generic"}:
            yield value
        for child in value.values():
            yield from iter_type_refs(child)
    elif isinstance(value, list):
        for child in value:
            yield from iter_type_refs(child)


def enrich_contract_metadata(surface: dict[str, Any]) -> bool:
    """Add deterministic behavior, auth, lifecycle, and documentation metadata."""

    changed = False

    def set_default(value: dict[str, Any], key: str, default: Any) -> None:
        nonlocal changed
        if key not in value:
            value[key] = default
            changed = True

    def visit(value: Any, path: tuple[str, ...]) -> None:
        if isinstance(value, dict):
            name = value.get("name")
            lineage = (*path, str(name)) if isinstance(name, str) and name else path
            documentable = (
                isinstance(name, str)
                and isinstance(value.get("visibility"), str)
                and value.get("kind") in {"class", "interface", "function", "type"}
            )
            callable_value = (
                isinstance(name, str)
                and "parameters" in value
                and "returns" in value
                and isinstance(value.get("async"), bool)
            )
            field_value = (
                isinstance(name, str)
                and isinstance(value.get("visibility"), str)
                and "type" in value
                and not callable_value
                and not documentable
            )
            if documentable or callable_value or field_value:
                identifier = ".".join(
                    re.sub(r"[^A-Za-z0-9_-]+", "-", part).strip("-") or "item"
                    for part in ("api", *lineage)
                )
                set_default(value, "documentationId", identifier)
                set_default(value, "stability", "stable")
                set_default(value, "deprecation", None)
            if callable_value:
                set_default(value, "behavior", "async" if value["async"] else "sync")
                set_default(value, "auth", {"mode": "none", "schemes": [], "scopes": []})
            for key, child in value.items():
                if key not in {"documentationId", "deprecation", "auth"}:
                    visit(child, (*path, str(key)))
        elif isinstance(value, list):
            for index, child in enumerate(value):
                visit(child, (*path, str(index)))

    visit(surface, ())
    return changed


def semantic_errors(surface: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    symbols = surface.get("symbols", [])
    names: list[str] = [str(item.get("name")) for item in symbols if isinstance(item, dict)]
    duplicates = sorted({name for name in names if names.count(name) > 1})
    if duplicates:
        errors.append(f"duplicate symbol names: {', '.join(duplicates)}")
    declared = set(names)
    for ref in iter_type_refs(surface):
        if ref.get("kind") == "named" and ref.get("name") not in declared:
            errors.append(f"unresolved named type: {ref.get('name')}")
    for kind in ("class", "interface", "type", "function"):
        for visibility in ("public", "private"):
            if not any(
                isinstance(item, dict)
                and item.get("kind") == kind
                and item.get("visibility") == visibility
                for item in symbols
            ):
                errors.append(f"missing {visibility} {kind} declaration")
    methods = [
        method
        for item in symbols
        if isinstance(item, dict)
        for method in item.get("methods", [])
        if isinstance(method, dict)
    ]
    for visibility in ("public", "private"):
        if not any(method.get("visibility") == visibility for method in methods):
            errors.append(f"missing {visibility} method declaration")

    documentation_ids: list[str] = []
    def inspect(value: Any) -> None:
        if isinstance(value, dict):
            documentation_id = value.get("documentationId")
            if isinstance(documentation_id, str):
                documentation_ids.append(documentation_id)
            if "parameters" in value and "returns" in value and isinstance(value.get("async"), bool):
                behavior = value.get("behavior")
                if behavior == "sync" and value["async"]:
                    errors.append(f"sync callable is marked async: {documentation_id or value.get('name')}")
                if behavior in {"async", "streaming"} and not value["async"]:
                    errors.append(f"{behavior} callable is not marked async: {documentation_id or value.get('name')}")
            if value.get("stability") == "deprecated" and value.get("deprecation") is None:
                errors.append(f"deprecated declaration lacks deprecation metadata: {documentation_id or value.get('name')}")
            for child in value.values():
                inspect(child)
        elif isinstance(value, list):
            for child in value:
                inspect(child)

    inspect(surface)
    duplicate_docs = sorted({item for item in documentation_ids if documentation_ids.count(item) > 1})
    if duplicate_docs:
        errors.append(f"duplicate documentation identifiers: {', '.join(duplicate_docs)}")
    return sorted(set(errors))


def choose_dir(root: Path, spec: TargetSpec, manifest_targets: dict[str, Any]) -> Path:
    target_names = (
        (spec.zed_target, *spec.zed_aliases)
        if spec.publish
        else spec.zed_aliases
    )
    for target_name in target_names:
        entry = manifest_targets.get(target_name)
        if isinstance(entry, dict) and isinstance(entry.get("dir"), str):
            declared = root / entry["dir"]
            if declared.exists():
                return declared
    canonical = root / spec.canonical_dir
    if canonical.exists():
        return canonical
    if spec.runtime:
        shared = root / "clients/typescript"
        runtime_source = shared / "src/runtimes" / spec.runtime
        package = shared / "package.json"
        if package.is_file() and runtime_source.exists():
            return shared
    for alias in spec.aliases:
        candidate = root / alias
        if candidate.exists():
            return candidate
    return canonical


def choose_target_dirs(root: Path, manifest_targets: dict[str, Any]) -> dict[str, Path]:
    """Choose one isolated source root for every canonical target.

    Older client manifests can expose several runtime aliases from one source
    directory (most commonly the shared ``clients/typescript`` package).  The
    current Zed manifest contract requires every target to own a distinct source
    root.  Preserve the first compatible legacy package, then materialize any
    colliding runtime at its deterministic canonical directory.

    Canonical directories are reserved for their owning target so a malformed
    legacy manifest cannot make an earlier target claim a later target's repair
    location.
    """

    repository_root = root.resolve()
    reserved = {
        (root / spec.canonical_dir).resolve(): spec.name
        for spec in TARGETS
    }
    claimed: set[Path] = set()
    selected: dict[str, Path] = {}
    for spec in TARGETS:
        preferred = choose_dir(root, spec, manifest_targets)
        resolved = preferred.resolve()
        if not resolved.is_relative_to(repository_root):
            preferred = root / spec.canonical_dir
            resolved = preferred.resolve()
        if not resolved.is_relative_to(repository_root):
            raise ValueError(f"target directory escapes repository for {spec.name}: {preferred}")
        reserved_for = reserved.get(resolved)
        if resolved in claimed or (reserved_for is not None and reserved_for != spec.name):
            preferred = root / spec.canonical_dir
            resolved = preferred.resolve()
        if not resolved.is_relative_to(repository_root):
            raise ValueError(f"target directory escapes repository for {spec.name}: {preferred}")
        if resolved in claimed:
            raise ValueError(f"canonical target directory collision for {spec.name}: {preferred}")
        claimed.add(resolved)
        selected[spec.name] = preferred
    return selected


def merge_missing_table(current: dict[str, Any], legacy: dict[str, Any]) -> None:
    """Deep-merge missing legacy metadata while canonical values win conflicts."""

    for key, value in legacy.items():
        existing = current.get(key)
        if isinstance(existing, dict) and isinstance(value, dict):
            merge_missing_table(existing, value)
        elif key not in current:
            current[key] = value


def marker_dir(root: Path, spec: TargetSpec, target_dir: Path) -> Path:
    shared_typescript = root / "clients/typescript"
    if spec.runtime and target_dir == shared_typescript:
        return shared_typescript / ".zed-contracts" / spec.runtime
    return target_dir


def extension_client_dirs(root: Path, target_dirs: dict[str, Path]) -> dict[str, Path]:
    """Return immediate client directories not owned by the standard matrix.

    Some repositories intentionally ship additional languages such as C#, Lua,
    OCaml, Scala, or shell.  They are not Zed publish targets, but they are still
    SDK implementations and therefore must carry the same API-surface contract.
    A standard target owns its immediate ``clients/<name>`` ancestor as well as
    its exact directory so nested TypeScript runtime packages are not mistaken
    for extensions.
    """

    clients_root = (root / "clients").resolve()
    if not clients_root.is_dir():
        return {}
    owned = {directory.resolve() for directory in target_dirs.values()}
    extensions: dict[str, Path] = {}
    for child in sorted(clients_root.iterdir(), key=lambda item: item.name):
        if not child.is_dir() or child.name.startswith("."):
            continue
        resolved = child.resolve()
        if any(directory == resolved or directory.is_relative_to(resolved) for directory in owned):
            continue
        extensions[child.name] = child
    return extensions


def has_product_implementation(directory: Path) -> bool:
    """Return true when a runtime already owns source code in its native layout."""

    source_roots = (
        directory / "src",
        directory / "lib",
        directory / "include",
        directory / "Sources",
        directory / "zed_pkg_client",
    )
    if any(root.is_dir() and any(item.is_file() for item in root.rglob("*")) for root in source_roots):
        return True
    return any((directory / filename).is_file() for filename in ("client.go", "mod.ts"))


def implementation_evidence(directory: Path) -> tuple[int, str]:
    """Return a deterministic digest of SDK source and export metadata."""

    records: list[dict[str, str]] = []
    for path in sorted(directory.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(directory)
        if CONTRACT_IGNORED_PARTS.intersection(relative.parts):
            continue
        if not (
            path.suffix.lower() in CONTRACT_SOURCE_SUFFIXES
            or path.name in CONTRACT_METADATA_NAMES
            or path.suffix.lower() in CONTRACT_METADATA_SUFFIXES
        ):
            continue
        records.append(
            {
                "path": relative.as_posix(),
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            }
        )
    records.sort(key=lambda item: item["path"])
    return len(records), digest(records)


def ensure_manifest(root: Path, org: str, repo: str, target_dirs: dict[str, Path], changed: list[str]) -> None:
    path = root / ".zpkg.toml"
    data = tomlkit.parse(path.read_text(encoding="utf-8")) if path.exists() else tomlkit.document()
    existing_targets = data.get("targets")
    if isinstance(existing_targets, dict):
        configured_target_dirs = [
            Path(target["dir"])
            for target in existing_targets.values()
            if isinstance(target, dict)
            and isinstance(target.get("dir"), str)
            and target["dir"] != "."
        ]
        safe_client_dirs = [
            directory
            for directory in configured_target_dirs
            if not directory.is_absolute()
            and ".." not in directory.parts
            and directory.parts
            and directory.parts[0] == "clients"
        ]
        if (
            # Existing fleets may publish a 13-target core while additional
            # runtime and extension directories remain contract-covered.
            len(safe_client_dirs) >= MINIMUM_TARGETS - 2
            and len(safe_client_dirs) == len(configured_target_dirs)
        ):
            # Mature repositories own their Zed target names, adapters, native
            # registry metadata, and runtime slicing. Contract hardening is
            # additive and must not rewrite an already complete publish matrix.
            return
    package = data.setdefault("package", tomlkit.table())
    if not isinstance(package, dict):
        raise ValueError(".zpkg.toml [package] must be a table")
    package["org"] = org
    package["name"] = repo
    package.setdefault("version", "0.1.0")
    package.setdefault("description", f"Polyglot client SDKs for {org}/{repo}.")
    package.setdefault("license", "MIT")
    repository = package.get("repository")
    if not isinstance(repository, dict):
        repository = tomlkit.table()
        package["repository"] = repository
    repository["vcs"] = "git"
    repository["url"] = f"https://github.com/{org}/{repo}"

    install = data.setdefault("install", tomlkit.table())
    if isinstance(install, dict):
        install.setdefault("dir", ".vendor/.zed")

    targets = data.setdefault("targets", tomlkit.table())
    if not isinstance(targets, dict):
        raise ValueError(".zpkg.toml [targets] must be a table")
    repository_target = targets.setdefault("repository", tomlkit.table())
    if isinstance(repository_target, dict):
        repository_target["dir"] = "."
        # Current zed-cli derives the whole-repository package name from
        # package.name. Remove the obsolete "<repo>-repository" override.
        repository_target.pop("name", None)
        # Early client repositories called the whole-repository release target
        # ``contract``.  Keeping both names points two targets at the same source
        # root and makes pre-publish validation ambiguous, so migrate the exact
        # root alias while preserving any non-layout metadata.
        legacy_contract = targets.get("contract")
        if isinstance(legacy_contract, dict) and legacy_contract.get("dir") == ".":
            merge_missing_table(repository_target, legacy_contract)
            repository_target["dir"] = "."
            repository_target.pop("adapter", None)
            del targets["contract"]

    for spec in TARGETS:
        if not spec.publish:
            for alias in spec.zed_aliases:
                targets.pop(alias, None)
            continue
        current = targets.get(spec.zed_target)
        for alias in spec.zed_aliases:
            if alias not in targets:
                continue
            legacy = targets.get(alias)
            if isinstance(legacy, dict):
                if not isinstance(current, dict):
                    current = legacy
                    targets[spec.zed_target] = current
                else:
                    merge_missing_table(current, legacy)
            del targets[alias]
        if not isinstance(current, dict):
            current = tomlkit.table()
            targets[spec.zed_target] = current
        current["dir"] = target_dirs[spec.name].relative_to(root).as_posix()
        current["adapter"] = spec.adapter
        published_name = current.get("name")
        if (
            isinstance(published_name, str)
            and VALID_ZED_TARGET_NAME.fullmatch(published_name) is None
        ):
            # Native registry coordinates remain under [targets.<name>.native].
            # Scoped npm coordinates are not valid Zed target names.
            del current["name"]

    rendered = tomlkit.dumps(data)
    tomllib.loads(rendered)
    write_text(path, rendered, changed)


def scaffold_target(
    root: Path,
    spec: TargetSpec,
    directory: Path,
    org: str,
    repo: str,
    prefix: str,
    changed: list[str],
) -> None:
    if has_product_implementation(directory):
        return

    cap = camel(prefix)
    s = snake(prefix)
    package = kebab(prefix)

    if spec.name == "c":
        write_text(directory / "CMakeLists.txt", f'''cmake_minimum_required(VERSION 3.20)
project({s}_client C)
add_library({s}_client src/{s}_client.c)
target_include_directories({s}_client PUBLIC include)
target_compile_features({s}_client PUBLIC c_std_11)
''', changed, missing_only=True)
        write_text(directory / f"include/{s}_client.h", f'''#ifndef {s.upper()}_CLIENT_H
#define {s.upper()}_CLIENT_H
#include <stdbool.h>
typedef struct {{ const char *base_url; const char *bearer_token; }} {s}_client;
{s}_client {s}_client_new(const char *base_url, const char *bearer_token);
bool {s}_client_health(const {s}_client *client);
#endif
''', changed, missing_only=True)
        write_text(directory / f"src/{s}_client.c", f'''#include "{s}_client.h"
{s}_client {s}_client_new(const char *base_url, const char *bearer_token) {{
  {s}_client value = {{base_url, bearer_token}}; return value;
}}
bool {s}_client_health(const {s}_client *client) {{ return client != 0 && client->base_url != 0; }}
''', changed, missing_only=True)
    elif spec.name == "cpp":
        write_text(directory / "CMakeLists.txt", f'''cmake_minimum_required(VERSION 3.20)
project({s}_client_cpp CXX)
add_library({s}_client_cpp INTERFACE)
target_include_directories({s}_client_cpp INTERFACE include)
target_compile_features({s}_client_cpp INTERFACE cxx_std_17)
''', changed, missing_only=True)
        write_text(directory / f"include/{s}/client.hpp", f'''#pragma once
#include <optional>
#include <string>
#include <utility>
namespace {s} {{
class {cap}Client final {{
 public:
  explicit {cap}Client(std::string base_url, std::optional<std::string> bearer_token = std::nullopt)
      : base_url_(std::move(base_url)), bearer_token_(std::move(bearer_token)) {{}}
  [[nodiscard]] bool health() const noexcept {{ return !base_url_.empty(); }}
 private:
  std::string base_url_;
  std::optional<std::string> bearer_token_;
}};
}}
''', changed, missing_only=True)
    elif spec.name == "zig":
        legacy_build = '''const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lib = b.addStaticLibrary(.{ .name = "client", .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    b.installArtifact(lib);
}
'''
        build = '''const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lib = b.addLibrary(.{
        .name = "client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(lib);
}
'''
        write_generated_text(
            directory / "build.zig",
            build,
            changed,
            previous_templates=(legacy_build,),
        )
        write_text(directory / "src/root.zig", '''pub const Client = struct {
    base_url: []const u8,
    bearer_token: ?[]const u8 = null,
    pub fn health(self: Client) bool { return self.base_url.len > 0; }
};
''', changed, missing_only=True)
    elif spec.name == "wasm":
        write_text(directory / "Cargo.toml", f'''[package]
name = "{package}-client-wasm"
version = "0.1.0"
edition = "2021"
[lib]
crate-type = ["cdylib", "rlib"]
''', changed, missing_only=True)
        write_text(directory / "src/lib.rs", '''#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Client { pub base_url: String, pub bearer_token: Option<String> }
impl Client {
    pub fn new(base_url: impl Into<String>, bearer_token: Option<String>) -> Self { Self { base_url: base_url.into(), bearer_token } }
    pub fn health(&self) -> bool { !self.base_url.is_empty() }
}
''', changed, missing_only=True)
    elif spec.name == "gleamlang":
        write_text(directory / "gleam.toml", f'''name = "{s}_client"
version = "0.1.0"
target = "erlang"
[dependencies]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
''', changed, missing_only=True)
        write_text(directory / f"src/{s}_client.gleam", '''import gleam/option.{type Option}

pub type Client {
  Client(base_url: String, bearer_token: Option(String))
}

pub fn new(base_url: String, bearer_token: Option(String)) -> Client {
  Client(base_url:, bearer_token:)
}

pub fn health(client: Client) -> Bool {
  client.base_url != ""
}
''', changed, missing_only=True)
    elif spec.name == "erlang":
        write_text(directory / "rebar.config", "{erl_opts, [debug_info, warnings_as_errors]}.\n", changed, missing_only=True)
        write_text(directory / f"src/{s}_client.erl", f'''-module({s}_client).
-export([new/2, health/1]).
new(BaseUrl, BearerToken) -> #{{base_url => BaseUrl, bearer_token => BearerToken}}.
health(Client) -> maps:get(base_url, Client, <<>>) =/= <<>>.
''', changed, missing_only=True)
    elif spec.name == "elixir":
        write_text(directory / "mix.exs", f'''defmodule {cap}Client.MixProject do
  use Mix.Project
  def project, do: [app: :{s}_client, version: "0.1.0", elixir: "~> 1.15"]
  def application, do: [extra_applications: [:logger]]
end
''', changed, missing_only=True)
        write_text(directory / f"lib/{s}_client.ex", f'''defmodule {cap}Client do
  @enforce_keys [:base_url]
  defstruct [:base_url, :bearer_token]
  def new(base_url, bearer_token \\ nil), do: %__MODULE__{{base_url: base_url, bearer_token: bearer_token}}
  def health(%__MODULE__{{base_url: url}}), do: url != ""
end
''', changed, missing_only=True)
    elif spec.name == "dart":
        write_text(directory / "pubspec.yaml", f'''name: {s}_client
version: 0.1.0
environment:
  sdk: ">=3.3.0 <4.0.0"
''', changed, missing_only=True)
        write_text(directory / f"lib/{s}_client.dart", f'''final class {cap}Client {{
  const {cap}Client({{required this.baseUrl, this.bearerToken}});
  final Uri baseUrl;
  final String? bearerToken;
  Future<bool> health() async => baseUrl.toString().isNotEmpty;
}}
''', changed, missing_only=True)
    elif spec.name == "rust":
        write_text(directory / "Cargo.toml", f'''[package]
name = "{package}-client"
version = "0.1.0"
edition = "2021"
''', changed, missing_only=True)
        write_text(directory / "src/lib.rs", '''#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Client { pub base_url: String, pub bearer_token: Option<String> }
impl Client {
    pub fn new(base_url: impl Into<String>, bearer_token: Option<String>) -> Self { Self { base_url: base_url.into(), bearer_token } }
    pub async fn health(&self) -> bool { !self.base_url.is_empty() }
}
''', changed, missing_only=True)
    elif spec.name == "java":
        java_pkg = f"io.zedpkg.{s}"
        java_path = java_pkg.replace(".", "/")
        write_text(directory / "settings.gradle.kts", f'rootProject.name = "{package}-client"\n', changed, missing_only=True)
        write_text(directory / "build.gradle.kts", '''plugins { `java-library` }
group = "io.zedpkg"
version = "0.1.0"
java { toolchain { languageVersion.set(JavaLanguageVersion.of(17)) } }
''', changed, missing_only=True)
        write_text(directory / f"src/main/java/{java_path}/{cap}Client.java", f'''package {java_pkg};
import java.net.URI;
public record {cap}Client(URI baseUrl, String bearerToken) {{
  public boolean health() {{ return baseUrl != null; }}
}}
''', changed, missing_only=True)
    elif spec.name == "golang":
        write_text(directory / "go.mod", f"module github.com/{org}/{repo}/clients/golang\n\ngo 1.22\n", changed, missing_only=True)
        write_text(directory / "client.go", f'''package {s}client
import "net/url"
type Client struct {{ BaseURL *url.URL; BearerToken string }}
func New(baseURL, bearerToken string) (*Client, error) {{ parsed, err := url.Parse(baseURL); if err != nil {{ return nil, err }}; return &Client{{BaseURL: parsed, BearerToken: bearerToken}}, nil }}
func (c *Client) Health() bool {{ return c != nil && c.BaseURL != nil }}
''', changed, missing_only=True)
    elif spec.name == "python3":
        write_text(directory / "pyproject.toml", f'''[build-system]
requires = ["setuptools>=69"]
build-backend = "setuptools.build_meta"
[project]
name = "{package}-client"
version = "0.1.0"
requires-python = ">=3.10"
''', changed, missing_only=True)
        write_text(directory / f"src/{s}_client/__init__.py", '''from .client import Client
__all__ = ["Client"]
''', changed, missing_only=True)
        write_text(directory / f"src/{s}_client/client.py", '''from dataclasses import dataclass
@dataclass(frozen=True, slots=True)
class Client:
    base_url: str
    bearer_token: str | None = None
    async def health(self) -> bool:
        return bool(self.base_url)
''', changed, missing_only=True)
    elif spec.name == "ruby":
        legacy_gemspec = f'''Gem::Specification.new do |spec|
  spec.name = "{package}-client"
  spec.version = "0.1.0"
  spec.summary = "Ruby client for {prefix}"
  spec.files = Dir["lib/**/*.rb"]
  spec.required_ruby_version = ">= 3.1"
end
'''
        legacy_standardizer_gemspec = f'''Gem::Specification.new do |spec|
  spec.name = "{package}-client"
  spec.version = "0.1.0"
  spec.summary = "Ruby client SDK for {prefix}"
  spec.files = Dir["lib/**/*.rb"]
  spec.required_ruby_version = ">= 3.1"
end
'''
        gemspec = f'''Gem::Specification.new do |spec|
  spec.name = "{package}-client"
  spec.version = "0.1.0"
  spec.summary = "Ruby client for {prefix}"
  spec.authors = ["{org} contributors"]
  spec.license = "MIT"
  spec.files = Dir["lib/**/*.rb"]
  spec.required_ruby_version = ">= 3.1"
end
'''
        write_generated_text(
            directory / f"{package}-client.gemspec",
            gemspec,
            changed,
            previous_templates=(legacy_gemspec, legacy_standardizer_gemspec),
        )
        write_text(directory / f"lib/{s}_client.rb", f'''class {cap}Client
  attr_reader :base_url, :bearer_token
  def initialize(base_url:, bearer_token: nil)
    @base_url = base_url
    @bearer_token = bearer_token
  end
  def health = !@base_url.empty?
end
''', changed, missing_only=True)
    elif spec.name == "php":
        namespace = f"ZedPkg\\{cap}"
        write_json(directory / "composer.json", {
            "name": f"{kebab(org)}/{package}-client",
            "type": "library",
            "require": {"php": ">=8.2"},
            "autoload": {"psr-4": {namespace + "\\": "src/"}},
        }, changed, missing_only=True)
        write_text(directory / "src/Client.php", f'''<?php
declare(strict_types=1);
namespace {namespace};
final readonly class Client {{
  public function __construct(public string $baseUrl, public ?string $bearerToken = null) {{}}
  public function health(): bool {{ return $this->baseUrl !== ''; }}
}}
''', changed, missing_only=True)
    elif spec.name == "kotlin":
        kotlin_pkg = f"io.zedpkg.{s}"
        kotlin_path = kotlin_pkg.replace(".", "/")
        write_text(directory / "settings.gradle.kts", f'rootProject.name = "{package}-client-kotlin"\n', changed, missing_only=True)
        write_text(directory / "build.gradle.kts", '''plugins { kotlin("jvm") version "2.0.21" }
group = "io.zedpkg"
version = "0.1.0"
repositories { mavenCentral() }
kotlin { jvmToolchain(17) }
''', changed, missing_only=True)
        write_text(directory / f"src/main/kotlin/{kotlin_path}/{cap}Client.kt", f'''package {kotlin_pkg}
import java.net.URI
data class {cap}Client(val baseUrl: URI, val bearerToken: String? = null) {{
  suspend fun health(): Boolean = baseUrl.toString().isNotEmpty()
}}
''', changed, missing_only=True)
    elif spec.name == "swift":
        write_text(directory / "Package.swift", f'''// swift-tools-version: 5.9
import PackageDescription
let package = Package(
  name: "{cap}Client",
  products: [.library(name: "{cap}Client", targets: ["{cap}Client"])],
  targets: [.target(name: "{cap}Client")]
)
''', changed, missing_only=True)
        write_text(directory / f"Sources/{cap}Client/Client.swift", '''import Foundation
public struct Client: Sendable {
  public let baseURL: URL
  public let bearerToken: String?
  public init(baseURL: URL, bearerToken: String? = nil) { self.baseURL = baseURL; self.bearerToken = bearerToken }
  public func health() async -> Bool { !baseURL.absoluteString.isEmpty }
}
''', changed, missing_only=True)
    elif spec.runtime:
        if directory == root / "clients/typescript":
            return
        source = '''export interface ClientOptions { readonly baseUrl: string; readonly bearerToken?: string }
export class Client {
  readonly baseUrl: URL;
  readonly bearerToken?: string;
  constructor(options: ClientOptions) { this.baseUrl = new URL(options.baseUrl); this.bearerToken = options.bearerToken; }
  async health(): Promise<boolean> { return this.baseUrl.href.length > 0; }
}
export function createClient(options: ClientOptions): Client { return new Client(options); }
'''
        if spec.runtime == "deno":
            write_json(directory / "deno.json", {"name": f"@{kebab(org)}/{package}-client-deno", "version": "0.1.0", "exports": "./mod.ts"}, changed, missing_only=True)
            write_text(directory / "mod.ts", source, changed, missing_only=True)
        else:
            write_json(directory / "package.json", {"name": f"@{kebab(org)}/{package}-client-{spec.runtime}", "version": "0.1.0", "type": "module", "exports": "./src/index.ts"}, changed, missing_only=True)
            write_text(directory / "src/index.ts", source, changed, missing_only=True)


def ensure_matrix(root: Path, target_dirs: dict[str, Path], changed: list[str]) -> None:
    matrix: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "minimum_targets": MINIMUM_TARGETS,
        "standard_target_count": len(TARGETS),
        "api_surface": "clients/api-surface.json",
        "api_schema": "clients/client-api.schema.json",
        "targets": {
            spec.name: {
                "dir": target_dirs[spec.name].relative_to(root).as_posix(),
                "zed_target": spec.zed_target,
                "runtime": spec.runtime or spec.name,
            }
            for spec in TARGETS
        },
    }
    write_json(root / "clients/client-contract-matrix.json", matrix, changed)


def ensure_contract(
    root: Path,
    schema_source: Path,
    org: str,
    repo: str,
    prefix: str,
    target_dirs: dict[str, Path],
    changed: list[str],
) -> tuple[dict[str, Any], str]:
    schema = json.loads(schema_source.read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(schema)
    write_json(root / "clients/client-api.schema.json", schema, changed)
    interfaces = declared_interface_sources(root)
    if not interfaces:
        raise ValueError(".zpkg.toml must declare at least one *-interfaces dependency")

    surface_path = root / "clients/api-surface.json"
    if surface_path.exists():
        surface = json.loads(surface_path.read_text(encoding="utf-8"))
        package = surface.setdefault("package", {})
        package["coordinate"] = f"{org}/{repo}"
        package.setdefault("namespace", camel(prefix))
        package["interfaces"] = interfaces
        surface["schemaVersion"] = SCHEMA_VERSION
        surface["$schema"] = "./client-api.schema.json"
        merge_standard_symbols(surface, str(package["namespace"]))
    else:
        surface = baseline_surface(org, repo, prefix, interfaces)

    enrich_contract_metadata(surface)
    validator = Draft202012Validator(schema)
    schema_errors = sorted(validator.iter_errors(surface), key=lambda item: list(item.absolute_path))
    if schema_errors:
        rendered = "; ".join(f"{'/'.join(map(str, item.absolute_path)) or '<root>'}: {item.message}" for item in schema_errors)
        raise ValueError(f"api surface does not satisfy client-api.schema.json: {rendered}")
    semantic = semantic_errors(surface)
    if semantic:
        raise ValueError("api surface semantic errors: " + "; ".join(semantic))

    write_json(surface_path, surface, changed)
    surface_digest = digest(surface)
    write_text(root / "clients/.api-surface.sha256", surface_digest, changed)

    contracts: list[dict[str, Any]] = []
    for spec in TARGETS:
        directory = target_dirs[spec.name]
        marker = marker_dir(root, spec, directory)
        contract = {
            "schemaVersion": SCHEMA_VERSION,
            "coordinate": f"{org}/{repo}",
            "target": spec.name,
            "zedTarget": spec.zed_target,
            "runtime": spec.runtime or spec.name,
            "apiSurface": "clients/api-surface.json",
            "apiSurfaceSha256": surface_digest,
            "schemaId": schema["$id"],
        }
        write_json(marker / ".zed-client-contract.json", contract, changed)
        write_text(marker / ".zed-api-surface.sha256", surface_digest, changed)
        implementation_file_count, implementation_digest = implementation_evidence(directory)
        contracts.append(
            {
                **contract,
                "dir": directory.relative_to(root).as_posix(),
                "implementationFileCount": implementation_file_count,
                "implementationSha256": implementation_digest,
            }
        )

    for name, directory in extension_client_dirs(root, target_dirs).items():
        target = f"extension-{kebab(name)}"
        contract = {
            "schemaVersion": SCHEMA_VERSION,
            "coordinate": f"{org}/{repo}",
            "target": target,
            "zedTarget": target,
            "runtime": name,
            "apiSurface": "clients/api-surface.json",
            "apiSurfaceSha256": surface_digest,
            "schemaId": schema["$id"],
        }
        write_json(directory / ".zed-client-contract.json", contract, changed)
        write_text(directory / ".zed-api-surface.sha256", surface_digest, changed)
        implementation_file_count, implementation_digest = implementation_evidence(directory)
        contracts.append(
            {
                **contract,
                "dir": directory.relative_to(root).as_posix(),
                "implementationFileCount": implementation_file_count,
                "implementationSha256": implementation_digest,
            }
        )

    write_json(
        root / "clients/contract-manifest.json",
        {
            "schemaVersion": SCHEMA_VERSION,
            "coordinate": f"{org}/{repo}",
            "apiSurfaceSha256": surface_digest,
            "targetCount": len(contracts),
            "targets": contracts,
        },
        changed,
    )
    return surface, surface_digest


def verify(root: Path, schema_source: Path) -> list[str]:
    errors: list[str] = []
    schema_path = root / "clients/client-api.schema.json"
    surface_path = root / "clients/api-surface.json"
    manifest_path = root / ".zpkg.toml"
    matrix_path = root / "clients/client-contract-matrix.json"
    contract_manifest_path = root / "clients/contract-manifest.json"
    if not schema_path.is_file():
        errors.append("missing clients/client-api.schema.json")
        return errors
    if not surface_path.is_file():
        errors.append("missing clients/api-surface.json")
        return errors
    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
        canonical_schema = json.loads(schema_source.read_text(encoding="utf-8"))
        if digest(schema) != digest(canonical_schema):
            errors.append("client-api.schema.json differs from canonical schema")
        Draft202012Validator.check_schema(schema)
        surface = json.loads(surface_path.read_text(encoding="utf-8"))
        for item in Draft202012Validator(schema).iter_errors(surface):
            errors.append(f"api-surface schema error at {'/'.join(map(str, item.absolute_path)) or '<root>'}: {item.message}")
        errors.extend(semantic_errors(surface))
        surface_digest = digest(surface)
    except (json.JSONDecodeError, ValueError) as exc:
        errors.append(str(exc))
        return errors

    if not manifest_path.is_file():
        errors.append("missing .zpkg.toml")
        return errors
    try:
        manifest = tomllib.loads(manifest_path.read_text(encoding="utf-8"))
    except (tomllib.TOMLDecodeError, OSError) as exc:
        errors.append(f"invalid .zpkg.toml: {exc}")
        return errors
    targets = manifest.get("targets", {})
    repository_root = root.resolve()
    target_owners: dict[Path, str] = {}
    if isinstance(targets, dict):
        for target_name, target in targets.items():
            if not isinstance(target, dict) or not isinstance(target.get("dir"), str):
                continue
            target_root = (root / target["dir"]).resolve()
            if not target_root.is_relative_to(repository_root):
                errors.append(f"target {target_name} source directory escapes repository: {target['dir']!r}")
                continue
            previous = target_owners.get(target_root)
            if previous is not None:
                errors.append(
                    f"targets {previous} and {target_name} share source directory {target['dir']!r}"
                )
            else:
                target_owners[target_root] = str(target_name)
    target_dirs = choose_target_dirs(root, targets if isinstance(targets, dict) else {})
    found = 0
    for spec in TARGETS:
        directory = target_dirs[spec.name].resolve()
        if not directory.is_relative_to(repository_root):
            errors.append(f"target {spec.name} source directory escapes repository: {directory}")
            continue
        if not directory.is_dir():
            errors.append(f"target {spec.name} points to missing directory: {directory}")
            continue
        found += 1
        marker = marker_dir(root, spec, directory)
        digest_path = marker / ".zed-api-surface.sha256"
        contract_path = marker / ".zed-client-contract.json"
        if not digest_path.is_file() or digest_path.read_text(encoding="utf-8").strip() != surface_digest:
            errors.append(f"{spec.name} API fingerprint is missing or stale")
        if not contract_path.is_file():
            errors.append(f"{spec.name} contract marker is missing")
        else:
            try:
                contract = json.loads(contract_path.read_text(encoding="utf-8"))
                if (
                    contract.get("apiSurfaceSha256") != surface_digest
                    or contract.get("target") != spec.name
                    or contract.get("zedTarget") != spec.zed_target
                ):
                    errors.append(f"{spec.name} contract marker does not match the canonical surface")
            except json.JSONDecodeError as exc:
                errors.append(f"{spec.name} contract marker is invalid JSON: {exc}")
    extensions = extension_client_dirs(root, target_dirs)
    for name, directory in extensions.items():
        target = f"extension-{kebab(name)}"
        digest_path = directory / ".zed-api-surface.sha256"
        contract_path = directory / ".zed-client-contract.json"
        if not digest_path.is_file() or digest_path.read_text(encoding="utf-8").strip() != surface_digest:
            errors.append(f"extension client {name} API fingerprint is missing or stale")
        if not contract_path.is_file():
            errors.append(f"extension client {name} contract marker is missing")
            continue
        try:
            contract = json.loads(contract_path.read_text(encoding="utf-8"))
            if (
                contract.get("apiSurfaceSha256") != surface_digest
                or contract.get("target") != target
                or contract.get("zedTarget") != target
                or contract.get("runtime") != name
            ):
                errors.append(f"extension client {name} contract marker does not match the canonical surface")
        except json.JSONDecodeError as exc:
            errors.append(f"extension client {name} contract marker is invalid JSON: {exc}")
    if found < MINIMUM_TARGETS:
        errors.append(f"only {found} targets are valid; at least {MINIMUM_TARGETS} are required")
    if found != len(TARGETS):
        errors.append(f"standard fleet target count is {found}; expected {len(TARGETS)}")
    if not contract_manifest_path.is_file():
        errors.append("missing clients/contract-manifest.json")
    else:
        try:
            contract_manifest = json.loads(contract_manifest_path.read_text(encoding="utf-8"))
            contract_targets = contract_manifest.get("targets", [])
            expected_count = len(TARGETS) + len(extensions)
            if contract_manifest.get("targetCount") != expected_count or len(contract_targets) != expected_count:
                errors.append(
                    "clients/contract-manifest.json target count does not cover the standard and extension client fleet"
                )
            for item in contract_targets:
                if not isinstance(item, dict) or not isinstance(item.get("dir"), str):
                    continue
                directory = (root / item["dir"]).resolve()
                if not directory.is_relative_to(root.resolve()) or not directory.is_dir():
                    continue
                implementation_file_count, implementation_digest = implementation_evidence(directory)
                if (
                    item.get("implementationFileCount") != implementation_file_count
                    or item.get("implementationSha256") != implementation_digest
                ):
                    errors.append(
                        f"{item.get('target', '<unknown>')} implementation source or export metadata drifted"
                    )
            declared_dirs = {
                item.get("dir")
                for item in contract_targets
                if isinstance(item, dict) and isinstance(item.get("dir"), str)
            }
            clients_root = root / "clients"
            uncovered = sorted(
                child.name
                for child in clients_root.iterdir()
                if child.is_dir()
                and not child.name.startswith(".")
                and not any(
                    (root / declared).resolve() == child.resolve()
                    or (root / declared).resolve().is_relative_to(child.resolve())
                    for declared in declared_dirs
                )
            )
            if uncovered:
                errors.append(f"client directories missing contract coverage: {', '.join(uncovered)}")
        except (json.JSONDecodeError, OSError, TypeError) as exc:
            errors.append(f"clients/contract-manifest.json is invalid: {exc}")
    if not matrix_path.is_file():
        errors.append("missing clients/client-contract-matrix.json")
    else:
        try:
            matrix = json.loads(matrix_path.read_text(encoding="utf-8"))
            matrix_targets = matrix.get("targets", {})
            if set(matrix_targets) != {spec.name for spec in TARGETS}:
                errors.append("clients/client-contract-matrix.json does not describe the standard runtime fleet")
        except (json.JSONDecodeError, OSError):
            errors.append("clients/client-contract-matrix.json is invalid JSON")
    return sorted(set(errors))


def infer_identity(root: Path, explicit_org: str | None, explicit_repo: str | None, explicit_prefix: str | None) -> tuple[str, str, str]:
    manifest: dict[str, Any] = {}
    path = root / ".zpkg.toml"
    if path.exists():
        try:
            manifest = tomllib.loads(path.read_text(encoding="utf-8"))
        except tomllib.TOMLDecodeError:
            manifest = {}
    package = manifest.get("package", {}) if isinstance(manifest, dict) else {}
    org = explicit_org or (package.get("org") if isinstance(package, dict) else None)
    repo = explicit_repo or (package.get("name") if isinstance(package, dict) else None) or root.name
    if not org:
        raise ValueError("--org is required when .zpkg.toml does not declare package.org")
    suffix = "-clients"
    prefix = explicit_prefix or (repo[: -len(suffix)] if repo.endswith(suffix) else repo)
    return str(org), str(repo), str(prefix)


def run(args: argparse.Namespace) -> dict[str, Any]:
    root = args.root.resolve()
    schema_source = args.schema.resolve()
    org, repo, prefix = infer_identity(root, args.org, args.repo, args.prefix)
    changed: list[str] = []

    manifest_targets: dict[str, Any] = {}
    manifest_path = root / ".zpkg.toml"
    if manifest_path.exists():
        try:
            parsed_manifest = tomllib.loads(manifest_path.read_text(encoding="utf-8"))
            raw_targets = parsed_manifest.get("targets", {})
            if isinstance(raw_targets, dict):
                manifest_targets = raw_targets
        except tomllib.TOMLDecodeError:
            manifest_targets = {}
    target_dirs = choose_target_dirs(root, manifest_targets)
    if args.write:
        for spec in TARGETS:
            directory = target_dirs[spec.name]
            directory.mkdir(parents=True, exist_ok=True)
            scaffold_target(root, spec, directory, org, repo, prefix, changed)
        ensure_manifest(root, org, repo, target_dirs, changed)
        ensure_matrix(root, target_dirs, changed)
        _, surface_digest = ensure_contract(root, schema_source, org, repo, prefix, target_dirs, changed)
    else:
        surface_path = root / "clients/api-surface.json"
        surface_digest = digest(json.loads(surface_path.read_text(encoding="utf-8"))) if surface_path.exists() else ""

    errors = verify(root, schema_source)
    result = {
        "schemaVersion": SCHEMA_VERSION,
        "repository": f"{org}/{repo}",
        "prefix": prefix,
        "mode": "write" if args.write else "check",
        "minimumTargets": MINIMUM_TARGETS,
        "standardTargets": len(TARGETS),
        "apiSurfaceSha256": surface_digest,
        "changed": sorted(set(changed)),
        "errors": errors,
    }
    if args.output:
        write_json(args.output, result, [])
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--schema", type=Path, required=True)
    parser.add_argument("--org")
    parser.add_argument("--repo")
    parser.add_argument("--prefix")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        result = run(args)
    except Exception as exc:  # noqa: BLE001 - CLI must report repository-specific failures.
        print(json.dumps({"errors": [f"{type(exc).__name__}: {exc}"]}, indent=2), file=sys.stderr)
        return 2
    print(json.dumps(result, indent=2, sort_keys=True))
    return 1 if result["errors"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
