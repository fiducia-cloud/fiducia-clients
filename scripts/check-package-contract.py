#!/usr/bin/env python3
"""Validate the fiducia-clients Zed package and real SDK implementation matrix."""

from __future__ import annotations

import datetime as dt
import json
import pathlib
import sys
import tomllib

ROOT = pathlib.Path(__file__).resolve().parents[1]

REQUIRED: dict[str, tuple[str, tuple[str, ...], tuple[str, ...]]] = {
    "c": ("clients/c", ("CMakeLists.txt", "Makefile", "meson.build"), (".c", ".h")),
    "cpp": ("clients/cpp", ("CMakeLists.txt", "Makefile", "meson.build"), (".cc", ".cpp", ".cxx", ".hpp", ".h")),
    "zig": ("clients/zig", ("build.zig", "build.zig.zon"), (".zig",)),
    "gleam": ("clients/gleam", ("gleam.toml",), (".gleam",)),
    "erlang": ("clients/erlang", ("rebar.config", "erlang.mk"), (".erl", ".hrl")),
    "elixir": ("clients/elixir", ("mix.exs",), (".ex", ".exs")),
    "dart": ("clients/dart", ("pubspec.yaml",), (".dart",)),
    "rust": ("clients/rust", ("Cargo.toml",), (".rs",)),
    "java": ("clients/java", ("pom.xml", "build.gradle", "build.gradle.kts"), (".java",)),
    "golang": ("clients/go", ("go.mod",), (".go",)),
    "python": ("clients/python", ("pyproject.toml", "setup.py", "setup.cfg"), (".py",)),
    "ruby": ("clients/ruby", ("zed_client.gemspec", "fiducia_client.gemspec", "fiducia-clients.gemspec", "Gemfile"), (".rb",)),
    "php": ("clients/php", ("composer.json",), (".php",)),
    "nodejs": ("clients/typescript", ("package.json", "tsconfig.json"), (".ts", ".tsx", ".js", ".mjs")),
    "kotlin": ("clients/kotlin", ("build.gradle.kts", "build.gradle", "pom.xml"), (".kt",)),
    "swift": ("clients/swift", ("Package.swift",), (".swift",)),
}


def load_toml(path: pathlib.Path) -> dict:
    with path.open("rb") as handle:
        return tomllib.load(handle)


def has_named_file(base: pathlib.Path, names: tuple[str, ...]) -> bool:
    return any((base / name).is_file() for name in names)


def has_source(base: pathlib.Path, suffixes: tuple[str, ...]) -> bool:
    return any(path.is_file() and path.suffix.lower() in suffixes for path in base.rglob("*"))


def main() -> int:
    errors: list[str] = []
    warnings: list[str] = []
    manifest = load_toml(ROOT / ".zpkg.toml")
    lock = load_toml(ROOT / ".zpkg.lock")
    exceptions = load_toml(ROOT / "zed-package-exceptions.toml")

    package = manifest.get("package", {})
    if package.get("org") != "fiducia-cloud" or package.get("name") != "fiducia-clients":
        errors.append("package identity must be fiducia-cloud/fiducia-clients")
    repository = package.get("repository", {})
    if repository.get("url") != "https://github.com/fiducia-cloud/fiducia-clients":
        errors.append("package.repository.url must match the canonical repository")

    dependencies = manifest.get("dependencies", {})
    if not isinstance(dependencies, dict) or "fiducia-cloud/fiducia-interfaces" not in dependencies:
        errors.append("fiducia-clients must depend on fiducia-cloud/fiducia-interfaces")
    for dependency in dependencies:
        leaf = dependency.rsplit("/", 1)[-1]
        if leaf.endswith("-infra") or leaf.endswith("-cli"):
            errors.append(f"forbidden client dependency: {dependency}")

    exception_records = exceptions.get("exception", [])
    lib_exception = next((item for item in exception_records if item.get("rule") == "clients-depend-on-lib"), None)
    if "fiducia-cloud/fiducia-lib" not in dependencies:
        if not isinstance(lib_exception, dict):
            errors.append("missing fiducia-lib dependency requires an explicit, expiring topology exception")
        else:
            try:
                expiry = dt.date.fromisoformat(str(lib_exception["expires"]))
            except (KeyError, ValueError):
                errors.append("fiducia-lib topology exception needs an ISO expiry date")
            else:
                if expiry < dt.date.today():
                    errors.append("fiducia-lib topology exception has expired")
                warnings.append("fiducia-lib repository is still missing; exception remains active")

    if lock.get("version") != 1:
        errors.append(".zpkg.lock must use version = 1")

    targets = manifest.get("targets", {})
    if not isinstance(targets, dict):
        errors.append("[targets] must be a table")
        targets = {}
    for target, (directory, markers, suffixes) in REQUIRED.items():
        record = targets.get(target)
        if not isinstance(record, dict):
            errors.append(f"missing [targets.{target}]")
            continue
        if record.get("dir") != directory:
            errors.append(f"targets.{target}.dir must be {directory!r}")
            continue
        base = ROOT / directory
        if not base.is_dir():
            errors.append(f"{target}: missing {directory}")
            continue
        if not has_named_file(base, markers):
            errors.append(f"{target}: no native package/build marker from {markers!r}")
        if not has_source(base, suffixes):
            errors.append(f"{target}: no implementation source with suffixes {suffixes!r}")

    for runtime_target in ("nodejs", "deno", "bun", "edge"):
        record = targets.get(runtime_target)
        if not isinstance(record, dict) or record.get("dir") != "clients/typescript":
            errors.append(f"TypeScript runtime target {runtime_target!r} is missing or points outside clients/typescript")

    matrix_path = ROOT / "clients/typescript/runtime-matrix.json"
    if not matrix_path.is_file():
        errors.append("clients/typescript/runtime-matrix.json is missing")
    else:
        try:
            matrix = json.loads(matrix_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            errors.append(f"invalid TypeScript runtime matrix: {exc}")
        else:
            runtimes = matrix.get("runtimes", {})
            for runtime in ("node", "deno", "bun", "edge"):
                record = runtimes.get(runtime)
                if not isinstance(record, dict) or record.get("supported") is not True or not str(record.get("smoke", "")).strip():
                    errors.append(f"TypeScript runtime {runtime!r} lacks support and a smoke command")

    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1
    for warning in warnings:
        print(f"warning: {warning}", file=sys.stderr)
    print(f"validated {len(REQUIRED)} real client slices plus Node, Deno, Bun, and edge runtimes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
