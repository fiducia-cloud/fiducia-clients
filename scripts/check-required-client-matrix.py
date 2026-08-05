#!/usr/bin/env python3
"""Validate Fiducia's required client matrix and Zed package routes."""

from __future__ import annotations

import json
from pathlib import Path
import re
import sys
import tomllib

ROOT = Path(__file__).resolve().parents[1]

PACKAGE = {
    "org": "fiducia-cloud",
    "name": "fiducia-clients",
    "version": "0.1.0",
    "license": "MIT",
}
REPOSITORY_URL = "https://github.com/fiducia-cloud/fiducia-clients"
INTERFACES_DEPENDENCY = "fiducia-cloud/fiducia-interfaces"

REQUIRED_TARGETS: dict[str, tuple[str, str | None]] = {
    "gleam": ("clients/gleam", None),
    "erlang": ("clients/erlang", None),
    "elixir": ("clients/elixir", None),
    "dart": ("clients/dart", "dart"),
    "rust": ("clients/rust", "rust"),
    "java": ("clients/java", "java"),
    "golang": ("clients/go", "go"),
    "python": ("clients/python", "python"),
    "ruby": ("clients/ruby", None),
    "php": ("clients/php", None),
    "nodejs": ("clients/ts", "node"),
    "deno": ("clients/ts", "none"),
    "bun": ("clients/ts", "node"),
    "edge": ("clients/ts", "none"),
    "kotlin": ("clients/kotlin", "java"),
    "swift": ("clients/swift", None),
}

NATIVE_MANIFESTS: dict[str, tuple[str, ...]] = {
    "gleam": ("gleam.toml",),
    "erlang": ("rebar.config",),
    "elixir": ("mix.exs",),
    "dart": ("pubspec.yaml",),
    "rust": ("Cargo.toml",),
    "java": ("pom.xml",),
    "golang": ("go.mod",),
    "python": ("pyproject.toml",),
    "ruby": ("fiducia-client.gemspec",),
    "php": ("composer.json",),
    "nodejs": ("package.json",),
    "deno": ("deno.json",),
    "bun": ("package.json",),
    "edge": ("package.json",),
    "kotlin": ("build.gradle.kts",),
    "swift": ("Package.swift",),
}


def fail(errors: list[str]) -> int:
    print("required-client-matrix: FAILED", file=sys.stderr)
    for error in errors:
        print(f"  - {error}", file=sys.stderr)
    return 1


def load_toml(path: Path, errors: list[str]) -> dict:
    try:
        with path.open("rb") as handle:
            return tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        errors.append(f"{path.relative_to(ROOT)} is invalid TOML: {exc}")
        return {}


def validate_zed(errors: list[str]) -> None:
    data = load_toml(ROOT / ".zpkg.toml", errors)
    package = data.get("package")
    if not isinstance(package, dict):
        errors.append("missing [package]")
        return

    for field, expected in PACKAGE.items():
        if package.get(field) != expected:
            errors.append(
                f"[package].{field} must be {expected!r}, got {package.get(field)!r}"
            )
    if not package.get("description"):
        errors.append("[package].description must be non-empty")

    repository = package.get("repository")
    if not isinstance(repository, dict):
        errors.append("missing [package.repository]")
    else:
        if repository.get("vcs") != "git":
            errors.append("[package.repository].vcs must be 'git'")
        if repository.get("url") != REPOSITORY_URL:
            errors.append(
                f"[package.repository].url must be {REPOSITORY_URL!r}"
            )

    if data.get("install", {}).get("dir") != ".vendor/.zed":
        errors.append("[install].dir must be '.vendor/.zed'")

    dependencies = data.get("dependencies")
    if not isinstance(dependencies, dict):
        errors.append("missing [dependencies]")
    elif INTERFACES_DEPENDENCY not in dependencies:
        errors.append(
            f"missing Zed dependency {INTERFACES_DEPENDENCY!r}"
        )

    targets = data.get("targets")
    if not isinstance(targets, dict):
        errors.append("missing [targets]")
        return

    for name, (directory, expected_adapter) in REQUIRED_TARGETS.items():
        target = targets.get(name)
        if not isinstance(target, dict):
            errors.append(f"missing [targets.{name}]")
            continue
        if target.get("dir") != directory:
            errors.append(
                f"[targets.{name}].dir must be {directory!r}, "
                f"got {target.get('dir')!r}"
            )
        if expected_adapter is not None and target.get("adapter") != expected_adapter:
            errors.append(
                f"[targets.{name}].adapter must be {expected_adapter!r}, "
                f"got {target.get('adapter')!r}"
            )

        target_dir = ROOT / directory
        if not target_dir.is_dir():
            errors.append(f"{name}: missing target directory {directory}")
            continue
        if not any(path.is_file() for path in target_dir.rglob("*")):
            errors.append(f"{name}: target directory {directory} is empty")
        for manifest in NATIVE_MANIFESTS[name]:
            if not (target_dir / manifest).is_file():
                errors.append(
                    f"{name}: missing native manifest {directory}/{manifest}"
                )

    runtime_dirs = {
        targets[name].get("dir")
        for name in ("nodejs", "deno", "bun", "edge")
        if isinstance(targets.get(name), dict)
    }
    if runtime_dirs != {"clients/ts"}:
        errors.append(
            "Node.js, Deno, Bun, and edge targets must share the "
            "self-contained clients/ts source root"
        )


def validate_typescript_runtime(errors: list[str]) -> None:
    source_paths = [ROOT / "clients/ts/fiducia.ts", ROOT / "clients/ts/locking.ts"]
    source = "\n".join(path.read_text(encoding="utf-8") for path in source_paths)

    forbidden = {
        "node: imports": r"(?:from\s+|import\s*)[\"']node:",
        "CommonJS require": r"\brequire\s*\(",
        "Node process globals": r"\bprocess\.",
    }
    for label, pattern in forbidden.items():
        if re.search(pattern, source):
            errors.append(f"TypeScript core contains {label}; edge target is not portable")

    try:
        package = json.loads(
            (ROOT / "clients/ts/package.json").read_text(encoding="utf-8")
        )
    except (OSError, json.JSONDecodeError) as exc:
        errors.append(f"clients/ts/package.json is invalid: {exc}")
    else:
        if package.get("name") != "@fiducia/client":
            errors.append("clients/ts/package.json has an unexpected package name")
        if package.get("type") != "module":
            errors.append("clients/ts/package.json must use ESM")

    try:
        deno = json.loads(
            (ROOT / "clients/ts/deno.json").read_text(encoding="utf-8")
        )
    except (OSError, json.JSONDecodeError) as exc:
        errors.append(f"clients/ts/deno.json is invalid: {exc}")
    else:
        exports = deno.get("exports")
        if exports != {".": "./fiducia.ts", "./locking": "./locking.ts"}:
            errors.append("clients/ts/deno.json exports must expose fiducia and locking")
        imports = deno.get("imports")
        if not isinstance(imports, dict) or not imports.get(
            "@fiducia/interfaces/typescript"
        ):
            errors.append(
                "clients/ts/deno.json must map @fiducia/interfaces/typescript"
            )


def main() -> int:
    errors: list[str] = []
    validate_zed(errors)
    validate_typescript_runtime(errors)

    if errors:
        return fail(errors)

    print(
        "required-client-matrix: OK "
        f"({len(REQUIRED_TARGETS)} required targets; "
        "Node.js/Deno/Bun/edge share clients/ts)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
