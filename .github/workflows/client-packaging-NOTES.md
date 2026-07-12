# client-packaging — verification notes

Two-tier design (reviewer "Codex") implemented in `client-packaging.yml`. Every job is
`continue-on-error: true`, short-timeout, network-allowed. MATLAB is **excluded** (no CI
runner / proprietary). `clojure` was not in the reviewer's original tier list; it was added
as a TIER A job at the coordinator's request and grounded locally.

"LOCALLY VERIFIED" = the pack/assert (and smoke where feasible) were run **green** on this
machine, in a temp dir **outside** the repo, against the **artifact** (not repo source).
No build artifacts were left in the repo.

## No packaging-drift found
Every `must_contain` assertion passed for every client that was run. No real artifact was
missing a needed source/module/header file. The issues surfaced were CI-config
requirements (below), not packaging drift.

## Per-client

| Client | Tier | pack_cmd (real publishable artifact) | must_contain | Local status |
|---|---|---|---|---|
| fsharp | A | `dotnet pack -c Release -o $tmp` → `.nupkg` | `lib/net6.0/Fiducia.FSharp.Client.dll` | **VERIFIED** — packed, consumer added the pkg from a local NuGet feed, `open Fiducia; FiduciaClient(...)` built |
| haskell | A | `cabal sdist -o $tmp` → `.tar.gz` | `fiducia-client-0.1.0/src/Fiducia.hs`, `…/fiducia-client.cabal` | **VERIFIED** — `cabal` via nix; sdist built; the sdist's module compiled with GHC 9.10.3 + real deps. (`cabal build all` from Hackage is the in-CI step; not separately run.) |
| erlang | A | `rebar3 hex build` → nested Hex `.tar` | outer: `contents.tar.gz`+`metadata.config`; inner: `src/fiducia.erl` | **VERIFIED** — Hex tarball built (OTP 28 / rebar3 3.27); inner source `erlc`-compiled to `fiducia.beam` |
| lua | A | `luarocks make --tree $tree <rockspec>` | `$tree/share/lua/*/fiducia.lua` | **VERIFIED*** — module installed into a temp tree + `require("fiducia")` returns `.new`. Local run stubbed the transport deps (luasocket/luasec/dkjson) and used `--deps-mode=none`; **CI installs the real deps** (`luarocks install` + `libssl-dev`). |
| nim | A | `nimble install --nimbleDir:$tmp` | `$tmp/pkgs2/fiducia-*/fiducia.nim` | **VERIFIED** — installed to temp; `import fiducia` (referencing `newClient`) checked from the artifact path. Negative control confirmed: import **fails** with no artifact path (proves not-from-repo). (nim 2.2.10) |
| scala | A | `sbt publishLocal` → `~/.ivy2/local/…jar` | `cloud/fiducia/FiduciaClient.class` | **VERIFIED** — `sbt` bootstrapped via coursier + Temurin 17; jar published & contains the class. (ivy pollution cleaned.) scala-cli consumer compile is the in-CI smoke. |
| kotlin | A | `gradle publishToMavenLocal` → `~/.m2/…jar` | `cloud/fiducia/FiduciaClient.class` | **NOT fully verified locally** — gradle config, plugins & publication graph loaded, but `kotlin { jvmToolchain(11) }` needs a **JDK 11** toolchain (machine has 17/26 only). CI uses `setup-java: 11`, which resolves it. Coordinates derived from `build.gradle.kts`. |
| clojure | A | `clojure -T:build jar` → `target/fiducia-client-0.1.0.jar` | `fiducia/client.clj` (jar also has `META-INF/maven/cloud.fiducia/fiducia-client/pom.xml`) | **VERIFIED** — built the jar; `require 'fiducia.client` FROM the jar via `-Sdeps :local/root` (+ `data.json`) in a temp dir outside the repo → "clojure artifact require OK". Negative control (no jar) **fails**, proving not-from-repo. (Clojure CLI 1.12.5 / Temurin 17) |
| c | A-compile | ship `fiducia.h`+`fiducia.c` (GitHub Release) | `fiducia.h`, `fiducia.c` | **VERIFIED** — external `consumer.c` `#include "fiducia.h"`, linked `fiducia.c` + `-lcurl`, ran (rc 0) |
| cpp | A-compile | ship `fiducia.hpp` (GitHub Release) | `fiducia.hpp` | **VERIFIED** — external `consumer.cpp` `#include "fiducia.hpp"` compiled `-std=c++17` with libcurl + nlohmann/json |
| zig | A-compile | tar of `build.zig.zon` `.paths` | `build.zig`, `build.zig.zon`, `src/fiducia.zig` | **VERIFIED** — tarball `zig fetch --save`d into a `zig init` consumer; `@import("fiducia")` referenced `fiducia.Client`; `zig build run` OK (0.16.0) |
| gleam | B | `git archive HEAD:clients/gleam` + `gleam build` | `gleam.toml`, `src/fiducia.gleam`, `manifest.toml` | **VERIFIED** — archive integrity + `gleam build` (deps fetched from Hex) (1.16.0) |
| swift | B | `git archive HEAD:clients/swift` + `swift build` | `Package.swift`, `Sources/Fiducia/Fiducia.swift` | **VERIFIED** — archive integrity + `swift build` (verified on macOS Swift 6.1.2; CI builds on the Ubuntu Swift toolchain) |
| crystal | B | `git archive HEAD:clients/crystal` | `shard.yml`, `src/fiducia.cr` | **VERIFIED** — archive integrity + zero-dep `crystal build --no-codegen` (1.20.3) |
| julia | B | `git archive HEAD:clients/julia` | `Project.toml`, `src/Fiducia.jl` | **VERIFIED** — archive integrity + Project.toml name/uuid sanity (1.12.6) |
| ocaml | B | `opam lint` + `dune build` + `git archive` | `lib/fiducia.ml`, `fiducia-client.opam` | **VERIFIED** — `opam lint` passed; `dune build` green against real deps (needs `opam env`; `setup-ocaml`/`opam exec` supplies it). Archive integrity OK. |
| r | B | `R CMD build .` → `.tar.gz` | `fiducia.client/R/fiducia.R`, `fiducia.client/DESCRIPTION` | **VERIFIED** — `R CMD build` produced the tarball, which contains `R/fiducia.R` (R 4.6.0) |
| matlab | — | EXCLUDED | — | excluded per reviewer |

`*` lua: locally verified with transport deps stubbed; CI performs the full real `require`.

## CI-config requirements surfaced by grounding (not packaging drift)
- **kotlin** — `jvmToolchain(11)` ⇒ the job MUST use `actions/setup-java` `java-version: 11`
  (encoded). Wrong/missing JDK 11 is the only reason the local run stopped.
- **ocaml** — `dune build` needs the opam switch env; the job uses `opam exec -- dune build`
  and `opam install . --deps-only` (opam depexts pull `libcurl` for the `curl`/`ezcurl` bindings).
- **lua** — `fiducia.lua` `require`s `socket.http`/`ltn12`/`dkjson` at load time, so the
  `require` smoke needs those deps installed; the job installs them + `libssl-dev` (luasec).
- **haskell** — `cabal check` emits only PVP version-bound warnings (`|| true`), non-fatal.
- **clojure** — a plain jar on the classpath via `:local/root` does not resolve the jar's
  pom deps, so the `require` smoke adds `org.clojure/data.json` alongside the artifact
  (a real Clojars/Maven consumer gets it transitively from the published pom).

## Toolchains used for local grounding
dotnet 10.0.108 · zig 0.16.0 · julia 1.12.6 · R 4.6.0 · gleam 1.16.0 · crystal 1.20.3 ·
ocaml 5.4.1 (+opam/dune, all client deps installed) · lua 5.5.0 + luarocks 3.13.0 ·
erlang OTP 28 + rebar3 3.27.0 · swift 6.1.2 · clang/gcc + libcurl + nlohmann/json ·
nim 2.2.10 + nimble 0.22.2 (side toolchain) · GHC 9.10.3 + cabal (via nix) ·
sbt (via coursier) + Temurin 17 · Clojure CLI 1.12.5 + Temurin 17. Not present as system
tools: gradle (downloaded 8.10.2 for the local kotlin attempt), a JDK 11.
