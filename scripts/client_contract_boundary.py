"""Pure boundary checks for polyglot *-clients JSON Schema contracts.

Inputs and outputs are explicit. Values are treated as immutable snapshots.
Effects (filesystem, process exit) stay in callers.
"""

from __future__ import annotations

from copy import deepcopy
from typing import Any, Iterator


def named_refs(value: Any) -> Iterator[str]:
    """Yield every named type reference in a contract fragment."""
    if isinstance(value, dict):
        if value.get("kind") == "named" and isinstance(value.get("name"), str):
            yield value["name"]
        for child in value.values():
            yield from named_refs(child)
    elif isinstance(value, list):
        for child in value:
            yield from named_refs(child)


def public_fragments(symbol: dict[str, Any]) -> list[dict[str, Any]]:
    """Return public-only fragments of one symbol; private members are excluded."""
    if symbol.get("visibility") != "public":
        return []
    base = {
        key: value
        for key, value in symbol.items()
        if key not in {"fields", "methods", "constructors", "definition"}
    }
    fragments = [base]
    for key in ("fields", "methods", "constructors"):
        fragments.extend(
            member
            for member in symbol.get(key, [])
            if isinstance(member, dict) and member.get("visibility") == "public"
        )
    definition = symbol.get("definition")
    if isinstance(definition, dict):
        if definition.get("kind") == "object":
            fragments.extend(
                field
                for field in definition.get("fields", [])
                if isinstance(field, dict) and field.get("visibility") == "public"
            )
        else:
            fragments.append(definition)
    return fragments


def private_symbol_names(symbols: list[Any]) -> frozenset[str]:
    return frozenset(
        symbol["name"]
        for symbol in symbols
        if isinstance(symbol, dict)
        and symbol.get("visibility") == "private"
        and isinstance(symbol.get("name"), str)
    )


def boundary_errors(document: dict[str, Any]) -> tuple[str, ...]:
    """Typed error list: empty means the public surface does not name private types."""
    symbols = document.get("symbols")
    if not isinstance(symbols, list) or not symbols:
        return ("contract has no symbols",)
    private_names = private_symbol_names(symbols)
    errors: list[str] = []
    for symbol in symbols:
        if not isinstance(symbol, dict):
            continue
        for fragment in public_fragments(symbol):
            leaked = sorted(set(named_refs(fragment)) & private_names)
            if leaked:
                errors.append(f'{symbol.get("name", "<unnamed>")}: {", ".join(leaked)}')
    return tuple(errors)


def private_leak_canary(document: dict[str, Any]) -> dict[str, Any]:
    """Return a mutated copy that must fail boundary_errors (negative test)."""
    mutant = deepcopy(document)
    mutant.setdefault("symbols", []).extend(
        [
            {
                "name": "__private_boundary_canary",
                "kind": "opaque",
                "visibility": "private",
            },
            {
                "name": "__public_boundary_canary",
                "kind": "function",
                "visibility": "public",
                "returns": {
                    "kind": "named",
                    "name": "__private_boundary_canary",
                },
            },
        ]
    )
    return mutant


CORE_CLIENT_ALIASES = {
    "dart": frozenset({"dart"}),
    "rust": frozenset({"rust"}),
    "typescript": frozenset({"typescript", "ts", "nodejs"}),
}


def client_directory_names(names: tuple[str, ...]) -> tuple[str, ...]:
    return tuple(sorted(name for name in names if name and not name.startswith(".")))


def missing_core_targets(directory_names: tuple[str, ...]) -> tuple[str, ...]:
    present = set(directory_names)
    missing = [
        core
        for core, aliases in CORE_CLIENT_ALIASES.items()
        if present.isdisjoint(aliases)
    ]
    return tuple(sorted(missing))
