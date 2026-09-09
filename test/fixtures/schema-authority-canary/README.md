# Independent schema-authority CI fixture

`main.tsp` and `authored.schema.json` are independently maintained peer authorities for this repository's parity-gate fixture. Neither file is generated from, ranked below, or allowed to overwrite the other.

CI runs `ORESoftware/typespec-json-schema-validator` at immutable revision `2281843126ab644607b11cf8281d84f382d68dfc`. It generates JSON Schema B from TypeSpec only into `.typespec-json-schema-validator/generated/`, validates both JSON Schema lanes as Draft 2020-12, compares top-level declarations and normalized semantics, and executes bidirectional instance probes. The generated witness, deterministic report, Contract IR and SARIF are evidence only.

After fresh compiler-backed parity, the workflow invokes the validator's canonical consumer verifier against the complete two-declaration scope and proves nineteen altered-evidence or incomplete-scope cases stop evaluation. Only then does it execute `scripts/check-required-client-matrix.py`, so the repository's declared polyglot client-language witness cannot be promoted from a stale, partial, or mismatched Contract IR.

A passing fixture proves this repository executes the fail-closed gate and exact-evidence consumer admission. It does not move Fiducia product schema ownership into the clients repository and does not certify unrelated product contracts. Canonical product authorities remain in `fiducia-cloud/fiducia-interfaces`; any unexplained mismatch stops evaluation and blocks promotion.
