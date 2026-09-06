# Ores lint bundle provenance

This directory is a reviewed vendored policy runtime, not generated application code.

The restored runtime is semantically based on the complete Ores lint bundle reviewed at:

- repository: `ORESoftware/flags-2-env`
- revision: `5a44d6a38f06c2765e80676618fd72bf4e59b984`
- bundle version: `1.4.0`

The earlier Fiducia rollout committed only part of that runtime: its workflows invoked `lint.sh`, while `eslint.config.mjs` imported an `eslint/base.mjs` file that did not exist. This repository therefore failed before any project linting occurred.

Repository-specific changes must preserve these invariants:

- missing optional language tools produce an explicit coverage gap, not a false pass;
- Ores logger chains are checked for terminal delivery;
- JavaScript and TypeScript reporting is capped and attributable;
- lint tooling never mutates source files;
- CI action references remain immutable;
- broad warning-only fleet linting is not represented as a compiler or release gate.

Update the whole runtime coherently. Do not copy only `lint.sh` or only the ESLint config factory.
