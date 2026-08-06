# Fiducia client support tiers

This document is the human-readable policy for how `clients/*` language folders are supported. The matching machine-readable inventory is `clients/support-tiers.json`; CI requires the directory tree, generator outputs, Zed publication targets, maintenance classification, and this policy to agree.

The paired policy and inventory exist to prevent two recurring failure modes:

1. treating generated preview clients as production-supported because a folder exists; and
2. opening duplicate "add language" work for languages that already have a folder but still need conformance, packaging, and ergonomic promotion work.

The canonical API contract remains `operations.json` plus `PROTOCOL.md`. A language client must not invent a divergent API shape, error taxonomy, retry rule, timeout behavior, or authentication/header contract.

## Current tiers

### Tier 1 — hard-gated production clients

These clients are the first production support tier and should block protocol drift in CI:

- `clients/ts`
- `clients/go`
- `clients/rust`
- `clients/python`

Required bar:

- generated operations are reproducible from `operations.json`;
- richer hand-maintained helpers live in reviewed templates or explicitly marked hand-maintained regions;
- conformance fixtures cover auth/header handling, locks, leases, fencing tokens, idempotency, retries, redirects, timeout/cancellation behavior, and JSON serialization;
- native package dry-runs pass, or the failure is tracked in Linear and classified as a release blocker.

### Tier 2 — supported generated/thin clients

These clients are first-party clients, but should be described as generated/thin until they have the same conformance and package-promotion evidence as Tier 1:

- `clients/dart`
- `clients/rust-wasm`
- `clients/java`
- `clients/csharp`
- `clients/ruby`
- `clients/php`
- `clients/powershell`
- `clients/shell`
- `clients/elixir`
- `clients/gleam`

Required bar:

- generation or hand-maintained exceptions are documented;
- package-manager dry-runs are wired where the ecosystem supports them;
- each client has a smoke example against the same canonical mock/test server;
- behavior that intentionally differs from Tier 1 is documented as a runtime constraint, not an accidental gap.

### Tier 3 — promotion candidates that already exist

The following clients already belong in the repo. They should not be tracked as new folder work. Track them as promotion/verification work instead:

- `clients/kotlin` — verify Kotlin-native ergonomics, nullability, coroutine posture, Gradle/Maven publication, and Android/JVM examples.
- `clients/swift` — verify SwiftPM metadata, `URLSession` transport, async/await examples, and Apple-platform packaging expectations.
- `clients/cpp` — verify CMake/pkg-config posture, dependency strategy, deterministic JSON/error mapping, and native infrastructure examples.
- `clients/erlang` — verify OTP-friendly API shape, rebar3/Hex metadata, `httpc`/JSON assumptions, supervision examples, and parity with—but not blind wrapping of—the Elixir client.
- `clients/c` — verify the C ABI/FFI boundary, ownership rules, JSON strategy, libcurl integration, memory-safety expectations, and header/source release artifacts.

Promotion checklist:

- conformance fixtures pass;
- package dry-run or release-artifact validation passes;
- docs include one end-to-end lock/lease/fencing-token example;
- timeout/cancellation/retry limitations are explicit;
- release ownership and support expectations are stated in `clients/PUBLISHING.md`.

### Tier 4 — preview or niche generated clients

These clients can remain first-party preview clients as long as they stay generated, package-checkable, and do not drag the API into divergent shapes:

- `clients/fsharp`
- `clients/ocaml`
- `clients/clojure`
- `clients/scala`
- `clients/zig`
- `clients/haskell`
- `clients/julia`
- `clients/r`
- `clients/matlab`
- `clients/nim`
- `clients/crystal`
- `clients/lua`

Do not remove a niche preview client merely because it is not a priority. Instead, demote it explicitly, skip publication if credentials/tooling are unavailable, and keep generation/package drift visible.

## Languages not currently justified as new first-party folders

Do not add new first-party folders for these without a customer pull, a downstream maintainer, or a specific integration need:

- Perl
- Groovy
- Objective-C
- Julia/R/MATLAB-like scientific variants beyond the existing preview clients
- additional ML/statistics or academic runtimes that can consume HTTP directly

A new language is justified only when it has a named owner, a package channel, conformance coverage, and a support-tier destination.

## Linear mapping

- `DEN-860` tracks the generator/conformance baseline for existing clients.
- `DEN-861` should track promotion and verification of existing Kotlin, Swift, C++, Erlang, and C clients, not creation of new folders.
- `DEN-709` remains the focused native-registry publishability repair for existing Rust, Go, and Java failures.

## Merge and conflict policy

When multiple branches touch client support tiers, merge semantically:

- preserve the canonical contract and support-tier definitions;
- keep real ecosystem-specific constraints even if another branch has cleaner prose;
- never accept a version that silently promotes a client without conformance evidence;
- never delete a generated preview client to make a matrix green unless the removal is explicitly documented and tracked;
- prefer adding a tier or support note over picking one side of a conflicting language list.
