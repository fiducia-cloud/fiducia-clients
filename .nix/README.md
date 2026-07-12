# .nix

Nix flake providing a reproducible development environment for the repo, with the
toolchains needed to build, test, and publish the many language clients.

- `flake.nix` — defines `devShells` across Linux/macOS (x86_64 + aarch64).
- `flake.lock` — pins the `nixpkgs` input (do not hand-edit).
