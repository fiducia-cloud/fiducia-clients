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
| `csharp` | NuGet Gallery | Packs into a fresh temp dir and requires `NUGET_API_KEY`. |
| `php` | Packagist | Composer validates and archives; if Packagist credentials are present, it triggers a package update. |
| `powershell` | PowerShell Gallery | Requires `POWERSHELL_GALLERY_API_KEY`. |
| `dart` | pub.dev | Stages `fiducia.dart` as `lib/fiducia_client.dart` with required package metadata, runs a dry-run, then publishes with `--force`. |
| `elixir` | Hex.pm | Builds with `mix hex.build`, then publishes with `mix hex.publish`. |
| `shell` | GitHub Releases | Tags `clients/shell/v${PACKAGE_VERSION}` and uploads `fiducia.sh`. |

Release the matching `fiducia-interfaces` packages before clients that re-export
generated types. At the moment that applies to npm `@fiducia/interfaces`, the
Rust `fiducia-interfaces` crate, and the Go
`github.com/fiducia-cloud/fiducia-interfaces/generated/go` module tag.

The goal is that users install the client with the native dependency manager
for their runtime instead of cloning the whole `fiducia-clients` repository.
