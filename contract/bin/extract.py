#!/usr/bin/env python3
"""
extract.py — toolchain-free extraction of a client's exported surface.

The point of this module is that it runs *everywhere*. A conformance gate that
needs 30 language toolchains installed before it can say anything is a gate that
gets disabled within a month. This reads source text and reports the public
symbols it declares, using per-language declaration patterns plus a paren-
balancing scan so multi-line signatures are handled correctly.

It is deliberately a *static* reader, not a compiler. It answers "does this
client declare an exported `lock_acquire` taking at least 2 required params",
which is exactly the question the contract asks. Deeper checks (does the built
artifact actually load, does the symbol resolve at runtime) belong to the
per-language native tests that this repo already runs; see check_surface.py's
--native flag for the hook.

Usage:
    extract.py <client-dir> [--lang LANG] [--json]
"""

import json
import os
import re
import sys

# --------------------------------------------------------------------------
# Language table
#
# Each entry:
#   exts        file extensions that belong to this language
#   patterns    (regex, name_group) pairs matched line-by-line; the parameter
#               list is read by balancing parens from the first '(' at or after
#               the match end, so wrapped signatures work.
#   comment     line-comment prefixes to skip
#   private     predicate(name, line) -> True if the symbol is NOT public
#   style       the naming style this language's surface uses
#   noparen     True when declarations routinely have no paren list (Haskell,
#               Erlang export lists, ...) so arity is taken from the pattern
# --------------------------------------------------------------------------

def _lead_underscore(name, _line):
    return name.startswith("_")


def _never(_name, _line):
    return False


def _not_capitalized(name, _line):
    return not (name[:1].isupper())


LANGS = {
    "python": {
        "exts": [".py"],
        "patterns": [(r"^\s*(?:async\s+)?def\s+([A-Za-z_]\w*)\s*\(", 1)],
        "comment": ["#"],
        "private": _lead_underscore,
        "style": "snake_case",
    },
    "ruby": {
        "exts": [".rb"],
        "patterns": [(r"^\s*def\s+(?:self\.)?([a-z_]\w*[!?=]?)", 1)],
        "comment": ["#"],
        "private": _lead_underscore,
        "style": "snake_case",
    },
    "go": {
        "exts": [".go"],
        "patterns": [(r"^func\s+(?:\([^)]*\)\s*)?([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*\(", 1)],
        "comment": ["//"],
        "private": _not_capitalized,
        "style": "PascalCase",
    },
    "rust": {
        "exts": [".rs"],
        "patterns": [(r"^\s*pub(?:\s*\([^)]*\))?\s+(?:async\s+)?fn\s+([A-Za-z_]\w*)\s*(?:<[^>]*>)?\s*\(", 1)],
        "comment": ["//"],
        "private": _never,
        "style": "snake_case",
    },
    "typescript": {
        "exts": [".ts", ".mts", ".tsx"],
        "patterns": [
            (r"^\s*export\s+(?:async\s+)?function\s+([A-Za-z_$][\w$]*)\s*(?:<[^>]*>)?\s*\(", 1),
            (r"^\s{2,}(?:public\s+|readonly\s+|override\s+)*(?:async\s+)?(?:static\s+)?([A-Za-z_$][\w$]*)\s*(?:<[^>]*>)?\s*\(", 1),
        ],
        "comment": ["//", "*", "/*"],
        "private": lambda n, line: n.startswith("_")
        or n in ("constructor", "if", "for", "while", "switch", "catch", "return", "super", "function")
        or "private " in line,
        "style": "camelCase",
    },
    "javascript": {
        "exts": [".js", ".mjs", ".cjs", ".jsx"],
        "patterns": [
            (r"^\s*export\s+(?:async\s+)?function\s+([A-Za-z_$][\w$]*)\s*\(", 1),
            (r"^\s{2,}(?:async\s+)?(?:static\s+)?([A-Za-z_$][\w$]*)\s*\(", 1),
        ],
        "comment": ["//", "*", "/*"],
        "private": lambda n, line: n.startswith("_")
        or n in ("constructor", "if", "for", "while", "switch", "catch", "return", "super", "function"),
        "style": "camelCase",
    },
    "java": {
        "exts": [".java"],
        "patterns": [(r"^\s*public\s+(?:static\s+|final\s+|synchronized\s+|native\s+)*[\w<>\[\],.\s?]+?\s+([A-Za-z_]\w*)\s*\(", 1)],
        "comment": ["//", "*", "/*"],
        "private": _never,
        "style": "camelCase",
    },
    "kotlin": {
        "exts": [".kt", ".kts"],
        "patterns": [(r"^\s*(?:public\s+)?(?:open\s+|override\s+|suspend\s+)*fun\s+(?:<[^>]*>\s*)?(?:[\w.]+\.)?([A-Za-z_]\w*)\s*\(", 1)],
        "comment": ["//", "*", "/*"],
        "private": lambda n, line: "private " in line or "internal " in line,
        "style": "camelCase",
    },
    "scala": {
        "exts": [".scala"],
        "patterns": [(r"^\s*def\s+([A-Za-z_]\w*)\s*[\(\[:]", 1)],
        "comment": ["//", "*", "/*"],
        "private": lambda n, line: "private" in line,
        "style": "camelCase",
    },
    "csharp": {
        "exts": [".cs"],
        "patterns": [(r"^\s*public\s+(?:async\s+|static\s+|virtual\s+|override\s+|sealed\s+)*[\w<>\[\],.?]+\s+([A-Za-z_]\w*)\s*\(", 1)],
        "comment": ["//", "*", "/*"],
        "private": _never,
        "style": "PascalCase",
    },
    "fsharp": {
        "exts": [".fs", ".fsi", ".fsx"],
        "patterns": [
            (r"^\s*member\s+(?:this|_|__|x)\.([A-Za-z_]\w*)", 1),
            (r"^\s*let\s+(?![_]|private\b)([A-Za-z_]\w*)", 1),
        ],
        "comment": ["//", "(*"],
        "private": lambda n, line: "private" in line,
        "style": "PascalCase",
    },
    "swift": {
        "exts": [".swift"],
        "patterns": [(r"^\s*(?:public\s+|open\s+)?(?:static\s+|class\s+)?func\s+([A-Za-z_]\w*)\s*(?:<[^>]*>)?\s*\(", 1)],
        "comment": ["//", "*", "/*"],
        "private": lambda n, line: "private " in line or "fileprivate " in line,
        "style": "camelCase",
    },
    "dart": {
        "exts": [".dart"],
        "patterns": [
            (r"^\s{2,}(?:Future<[^>]*>|Stream<[^>]*>|[A-Za-z_][\w<>,\s?\[\]]*?)\s+([A-Za-z_]\w*)\s*\(", 1),
            (r"^\s*(?:Future<[^>]*>|[A-Za-z_][\w<>,\s?\[\]]*?)\s+([A-Za-z_]\w*)\s*\(", 1),
        ],
        "comment": ["//", "*", "/*"],
        "private": lambda n, line: n.startswith("_")
        or n in ("if", "for", "while", "switch", "catch", "return", "assert", "print"),
        "style": "camelCase",
    },
    "php": {
        "exts": [".php"],
        "patterns": [(r"^\s*(?:public\s+|final\s+|static\s+)*function\s+([A-Za-z_]\w*)\s*\(", 1)],
        "comment": ["//", "#", "*", "/*"],
        "private": lambda n, line: "private " in line or "protected " in line or n.startswith("__"),
        "style": "camelCase",
    },
    "elixir": {
        "exts": [".ex", ".exs"],
        "patterns": [(r"^\s*def\s+([a-z_]\w*[!?]?)\s*[\(,\s]", 1)],
        "comment": ["#"],
        "private": _lead_underscore,
        "style": "snake_case",
    },
    "erlang": {
        "exts": [".erl", ".hrl"],
        "patterns": [(r"^\s*([a-z]\w*)\s*\(", 1)],
        "comment": ["%"],
        "private": _never,
        "style": "snake_case",
        "export_list": r"-export\(\[(.*?)\]\)",
    },
    "gleam": {
        "exts": [".gleam"],
        "patterns": [(r"^pub\s+fn\s+([a-z_]\w*)\s*\(", 1)],
        "comment": ["//"],
        "private": _never,
        "style": "snake_case",
    },
    "haskell": {
        "exts": [".hs"],
        "patterns": [(r"^([a-z]\w*)\s*::", 1)],
        "comment": ["--"],
        "private": _never,
        "style": "camelCase",
        "noparen": True,
    },
    "ocaml": {
        "exts": [".ml", ".mli"],
        "patterns": [(r"^\s*(?:val|let)\s+(?:rec\s+)?([a-z_]\w*)", 1)],
        "comment": ["(*"],
        "private": _lead_underscore,
        "style": "snake_case",
        "noparen": True,
    },
    "clojure": {
        "exts": [".clj", ".cljc", ".cljs"],
        "patterns": [(r"^\(defn\s+([A-Za-z_][\w\-\>\?\!\*\+]*)", 1)],
        "comment": [";"],
        "private": lambda n, line: "^:private" in line or "defn-" in line,
        "style": "kebab-case",
        "noparen": True,
    },
    "crystal": {
        "exts": [".cr"],
        "patterns": [(r"^\s*def\s+(?:self\.)?([a-z_]\w*[!?=]?)", 1)],
        "comment": ["#"],
        "private": lambda n, line: n.startswith("_") or "private def" in line,
        "style": "snake_case",
    },
    "nim": {
        "exts": [".nim"],
        "patterns": [(r"^\s*(?:proc|func)\s+([A-Za-z_]\w*)\*\s*\(", 1)],
        "comment": ["#"],
        "private": _never,
        "style": "camelCase",
    },
    "zig": {
        "exts": [".zig"],
        "patterns": [(r"^\s*pub\s+fn\s+([A-Za-z_]\w*)\s*\(", 1)],
        "comment": ["//"],
        "private": _never,
        "style": "camelCase",
    },
    "c": {
        "exts": [".c", ".h"],
        "patterns": [(r"^(?!static\b)[A-Za-z_][\w\s\*]*?\s\*?([A-Za-z_]\w*)\s*\(", 1)],
        "comment": ["//", "*", "/*"],
        "private": lambda n, line: n in ("if", "for", "while", "switch", "return", "sizeof"),
        "style": "snake_case",
    },
    "cpp": {
        "exts": [".cpp", ".cc", ".hpp", ".hh", ".hxx"],
        "patterns": [(r"^\s*(?!static\b)[A-Za-z_][\w\s\*&:<>,]*?\s\*?&?([A-Za-z_]\w*)\s*\(", 1)],
        "comment": ["//", "*", "/*"],
        "private": lambda n, line: n in ("if", "for", "while", "switch", "return", "sizeof", "catch"),
        "style": "snake_case",
    },
    "lua": {
        "exts": [".lua"],
        "patterns": [
            (r"^\s*function\s+[\w.]*[.:]([A-Za-z_]\w*)\s*\(", 1),
            (r"^\s*function\s+([A-Za-z_]\w*)\s*\(", 1),
            (r"^\s*(?:M|_M)\.([A-Za-z_]\w*)\s*=\s*function\s*\(", 1),
        ],
        "comment": ["--"],
        "private": _lead_underscore,
        "style": "snake_case",
    },
    "r": {
        "exts": [".R", ".r"],
        "patterns": [(r"^([A-Za-z_][\w.]*)\s*(?:<-|=)\s*function\s*\(", 1)],
        "comment": ["#"],
        "private": lambda n, line: n.startswith("."),
        "style": "snake_case",
    },
    "julia": {
        "exts": [".jl"],
        "patterns": [
            (r"^\s*function\s+([A-Za-z_]\w*!?)\s*\(", 1),
            (r"^([A-Za-z_]\w*!?)\s*\([^)]*\)\s*=", 1),
        ],
        "comment": ["#"],
        "private": _lead_underscore,
        "style": "snake_case",
    },
    "powershell": {
        "exts": [".ps1", ".psm1"],
        "patterns": [(r"^\s*function\s+([A-Za-z][\w-]*)", 1)],
        "comment": ["#"],
        "private": _never,
        "style": "PascalCase",
        "noparen": True,
    },
    "matlab": {
        "exts": [".m"],
        "patterns": [
            (r"^\s*function\s+(?:\[?[\w,\s]*\]?\s*=\s*)?([A-Za-z_]\w*)\s*\(", 1),
        ],
        "comment": ["%"],
        "private": _never,
        "style": "snake_case",
    },
    "shell": {
        "exts": [".sh", ".bash"],
        "patterns": [
            (r"^([A-Za-z_][\w:-]*)\s*\(\)\s*\{", 1),
            (r"^function\s+([A-Za-z_][\w:-]*)", 1),
        ],
        "comment": ["#"],
        "private": _lead_underscore,
        "style": "snake_case",
        "noparen": True,
    },
}

# clients/<dir> names seen across the fleet -> language id
DIR_ALIASES = {
    "ts": "typescript", "typescript": "typescript", "reactive-ts": "typescript",
    "js": "javascript", "node": "javascript",
    "go": "go", "golang": "go",
    "python": "python", "python3": "python", "py": "python",
    "rust": "rust", "rust-wasm": "rust", "rust-policy": "rust",
    "rust-connectivity": "rust", "rust-db": "rust", "desktop-rust": "rust",
    "gleam": "gleam", "gleamlang": "gleam",
    "dart": "dart", "flutter": "dart", "flutter_background": "dart", "reactive-dart": "dart",
    "csharp": "csharp", "dotnet": "csharp", "cs": "csharp",
    "fsharp": "fsharp",
    "cpp": "cpp", "c++": "cpp", "cxx": "cpp",
    "c": "c",
    "java": "java", "kotlin": "kotlin", "scala": "scala", "clojure": "clojure",
    "swift": "swift", "php": "php", "ruby": "ruby", "elixir": "elixir",
    "erlang": "erlang", "haskell": "haskell", "ocaml": "ocaml", "nim": "nim",
    "zig": "zig", "lua": "lua", "r": "r", "julia": "julia",
    "powershell": "powershell", "matlab": "matlab", "shell": "shell",
    "crystal": "crystal",
    "wasm": None,  # decided by extension census
}

SKIP_DIRS = {
    "node_modules", "target", "build", "dist", "vendor", ".git", "_build",
    "deps", "bin", "obj", "out", ".dart_tool", "Pods", "__pycache__",
    ".gradle", ".venv", "venv", "coverage", "zig-cache", "zig-out",
}

TEST_HINTS = ("test", "spec", "_test.", ".test.", "fixture", "example", "bench", "conformance")


def detect_language(client_dir, hint=None):
    """Pick the language for a clients/<dir>, by directory alias then by census."""
    base = os.path.basename(os.path.normpath(client_dir)).lower()
    if hint:
        return hint
    aliased = DIR_ALIASES.get(base, "MISSING")
    if aliased not in (None, "MISSING"):
        return aliased

    census = {}
    for path in iter_sources(client_dir, None):
        ext = os.path.splitext(path)[1]
        for lang, spec in LANGS.items():
            if ext in spec["exts"]:
                census[lang] = census.get(lang, 0) + os.path.getsize(path)
    if not census:
        return None
    # .h is ambiguous between c and cpp; prefer whichever has more bytes.
    return max(census.items(), key=lambda kv: kv[1])[0]


def iter_sources(client_dir, lang, exclude=()):
    exts = LANGS[lang]["exts"] if lang else None
    for root, dirs, files in os.walk(client_dir):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".")]
        for name in sorted(files):
            if exts and os.path.splitext(name)[1] not in exts:
                continue
            rel = os.path.relpath(os.path.join(root, name), client_dir)
            low = rel.lower()
            if any(h in low for h in TEST_HINTS):
                continue
            if any(_glob_match(rel, pat) for pat in exclude):
                continue
            yield os.path.join(root, name)


def _glob_match(rel, pattern):
    import fnmatch
    return fnmatch.fnmatch(rel, pattern)


def _read_params(text, start):
    """Balance-scan a parameter list starting at the '(' found at/after `start`.

    Returns (params_text, count_of_top_level_params) or (None, None) when no
    paren list is present within a reasonable lookahead.
    """
    open_idx = text.find("(", start)
    if open_idx == -1 or open_idx - start > 200:
        return None, None
    depth = 0
    i = open_idx
    in_str = None
    while i < len(text):
        ch = text[i]
        if in_str:
            if ch == "\\":
                i += 2
                continue
            if ch == in_str:
                in_str = None
        elif ch in "\"'":
            in_str = ch
        elif ch in "([{<":
            if ch != "<":
                depth += 1
        elif ch in ")]}>":
            if ch != ">":
                depth -= 1
                if depth == 0:
                    inner = text[open_idx + 1 : i]
                    return inner, _count_params(inner)
        i += 1
    return None, None


def _count_params(inner):
    if not inner.strip():
        return 0
    depth = 0
    count = 1
    in_str = None
    for ch in inner:
        if in_str:
            if ch == in_str:
                in_str = None
            continue
        if ch in "\"'":
            in_str = ch
        elif ch in "([{<":
            depth += 1
        elif ch in ")]}>":
            depth -= 1
        elif ch == "," and depth == 0:
            count += 1
    return count


def _is_comment(line, prefixes):
    s = line.strip()
    return any(s.startswith(p) for p in prefixes)


def extract(client_dir, lang=None, exclude=()):
    """Return {"language": lang, "symbols": {name: {...}}, "files": n}."""
    lang = lang or detect_language(client_dir)
    if lang is None or lang not in LANGS:
        return {"language": lang, "symbols": {}, "files": 0, "unsupported": True}

    spec = LANGS[lang]
    symbols = {}
    nfiles = 0

    for path in iter_sources(client_dir, lang, exclude):
        nfiles += 1
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue

        # Erlang states its surface explicitly; trust the -export list.
        if spec.get("export_list"):
            for block in re.findall(spec["export_list"], text, re.S):
                for entry in block.split(","):
                    entry = entry.strip()
                    m = re.match(r"([a-z]\w*)\s*/\s*(\d+)", entry)
                    if m:
                        _add(symbols, m.group(1), int(m.group(2)), path, client_dir)
            continue

        offset = 0
        for line in text.splitlines(keepends=True):
            stripped = line
            if not _is_comment(line, spec["comment"]):
                for pattern, grp in spec["patterns"]:
                    m = re.search(pattern, stripped)
                    if not m:
                        continue
                    name = m.group(grp)
                    if spec["private"](name, line):
                        continue
                    if spec.get("noparen"):
                        arity = None
                    else:
                        _params, arity = _read_params(text, offset + m.end() - 1)
                    _add(symbols, name, arity, path, client_dir)
                    break
            offset += len(line)

    return {"language": lang, "symbols": symbols, "files": nfiles}


def _add(symbols, name, arity, path, client_dir):
    rel = os.path.relpath(path, client_dir)
    entry = symbols.setdefault(name, {"arity": arity, "files": []})
    if rel not in entry["files"]:
        entry["files"].append(rel)
    # Keep the widest arity seen: overloads and optional args both widen it.
    if arity is not None and (entry["arity"] is None or arity > entry["arity"]):
        entry["arity"] = arity


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    client_dir = argv[0]
    lang = None
    if "--lang" in argv:
        lang = argv[argv.index("--lang") + 1]
    result = extract(client_dir, lang)
    if "--json" in argv:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print("language: %s  files: %d  symbols: %d" % (result["language"], result["files"], len(result["symbols"])))
        for name in sorted(result["symbols"]):
            info = result["symbols"][name]
            print("  %-40s arity=%s  %s" % (name, info["arity"], info["files"][0]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))


TYPE_DECL = re.compile(
    r"\b(?:class|struct|interface|type|record|object|defmodule|module|enum|trait|protocol|typedef struct)\s+"
    r"([A-Za-z_][A-Za-z0-9_]*)"
)


def find_client_type(client_dir, lang=None, prefer=None):
    """Best guess at the primary exported client type's real spelling.

    Languages disagree about how a product slug becomes a type name (3fa ->
    ThreeFA, opto-sync -> OptoSync), so read it off the source instead of
    deriving it and being wrong in a way that produces noise forever.
    """
    lang = lang or detect_language(client_dir)
    if lang not in LANGS:
        return None
    found = set()
    for path in iter_sources(client_dir, lang):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        for name in TYPE_DECL.findall(text):
            if name.lower().endswith("client"):
                found.add(name)
    if not found:
        return None
    if prefer and prefer in found:
        return prefer
    # The plain client beats decorated siblings (FiduciaClient over
    # FiduciaLockClient), so shortest wins.
    return sorted(found, key=lambda n: (len(n), n))[0]
