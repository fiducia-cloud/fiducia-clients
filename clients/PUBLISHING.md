# Publishing Fiducia Clients

Each language folder has a `publish.sh` entrypoint. By default it prints the
native package-manager command without publishing anything:

```sh
clients/ts/publish.sh
clients/python/publish.sh --dry-run
clients/java/publish.sh --release
```

Use `--release` only from CI or a workstation where the target registry
credentials are already configured. Release commands that create git tags also
require a clean worktree before they tag or push.

| Client | Registry or channel | Release notes |
| --- | --- | --- |
| `ts` | npm | Publishes `@fiducia/client` with public access. |
| `python` | PyPI | Builds into a fresh temp dir, checks with `twine`, uploads with `twine upload`. |
| `java` | Maven Central and Artifactory | `FIDUCIA_MAVEN_TARGET` can be `central`, `artifactory`, or `both`; Artifactory releases require `ARTIFACTORY_URL`. |
| `ruby` | RubyGems.org | Builds `fiducia-client.gemspec`, then pushes only the newly built gem. |
| `go` | Go module proxy | Tags `clients/go/v${PACKAGE_VERSION}` and pushes the tag. |
| `rust` | crates.io | Runs `cargo package`, then `cargo publish`. |
| `rust-wasm` | npm | `wasm-pack build --target bundler --release` compiles the cdylib and emits an npm package under `pkg/` (with `.d.ts`); publishes it with `npm publish pkg --access public`. Needs `wasm-pack` + the `wasm32-unknown-unknown` target. |
| `csharp` | NuGet Gallery | Packs into a fresh temp dir and requires `NUGET_API_KEY`. |
| `php` | Packagist | Composer validates and archives; if Packagist credentials are present, it triggers a package update. |
| `powershell` | PowerShell Gallery | Requires `POWERSHELL_GALLERY_API_KEY`. |
| `dart` | pub.dev | Stages `fiducia.dart` as `lib/fiducia_client.dart` with required package metadata, runs a dry-run, then publishes with `--force`. |
| `elixir` | Hex.pm | Builds with `mix hex.build`, then publishes with `mix hex.publish`. |
| `shell` | GitHub Releases | Tags `clients/shell/v${PACKAGE_VERSION}` and uploads `fiducia.sh`. |
| `gleam` | Hex.pm | `gleam publish` builds and uploads the package (needs a Hex API key). |
| `fsharp` | NuGet Gallery | Packs into a fresh temp dir and pushes; requires `NUGET_API_KEY`. |
| `ocaml` | opam repository | Lints the `.opam`, `dune build`, then `opam publish` opens the opam-repository PR. |
| `clojure` | Clojars | `clojure -T:build deploy` (deps-deploy); requires `CLOJARS_USERNAME`/`CLOJARS_PASSWORD`. |
| `scala` | Maven Central | `sbt +publish` to Sonatype; requires signing + Sonatype credentials. |
| `kotlin` | Maven Central and Artifactory | `gradle publish` (maven-publish + signing); requires the target repo credentials. |
| `erlang` | Hex.pm | `rebar3 hex publish` via the `rebar3_hex` plugin. |
| `swift` | Swift Package Manager | Tags `clients/swift/v${PACKAGE_VERSION}`; consumed by git tag (indexed by the Swift Package Index). |
| `cpp` | GitHub Releases | Tags `clients/cpp/v${PACKAGE_VERSION}` and uploads `fiducia.hpp`. |
| `c` | GitHub Releases | Tags `clients/c/v${PACKAGE_VERSION}` and uploads `fiducia.h` / `fiducia.c`. |
| `zig` | GitHub Releases | Tags `clients/zig/v${PACKAGE_VERSION}`; consumed via `zig fetch` + `build.zig.zon`. |
| `haskell` | Hackage | Builds the sdist with `cabal sdist`, then `cabal upload --publish`. |
| `julia` | Julia General registry | Tags `clients/julia/v${PACKAGE_VERSION}`; register by commenting `@JuliaRegistrator` on the release. |
| `r` | CRAN / R-universe | `R CMD build` produces the tarball; CRAN submission is manual, R-universe builds from the repo. |
| `matlab` | MATLAB File Exchange | Tags `clients/matlab/v${PACKAGE_VERSION}` and uploads `Fiducia.m`; File Exchange links the GitHub release. |
| `nim` | Nimble | `nimble publish` registers the package in the `nim-lang/packages` directory. |
| `crystal` | Shards (GitHub Releases) | Tags `clients/crystal/v${PACKAGE_VERSION}`; shards resolve the dependency by git tag. |
| `lua` | LuaRocks | `luarocks upload` the rockspec; requires `LUAROCKS_API_KEY` and `PACKAGE_VERSION`. |

Release the matching `fiducia-interfaces` packages before clients that re-export
generated types. At the moment that applies to npm `@fiducia/interfaces`, the
Rust `fiducia-interfaces` crate, and the Go
`github.com/fiducia-cloud/fiducia-interfaces/generated/go` module tag.

The goal is that users install the client with the native dependency manager
for their runtime instead of cloning the whole `fiducia-clients` repository.
