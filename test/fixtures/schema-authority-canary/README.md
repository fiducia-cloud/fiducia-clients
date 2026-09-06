# Independent schema-authority CI fixture

`main.tsp` and `authored.schema.json` are independently maintained peer authorities for this repository's parity-gate fixture. Neither file is generated from, ranked below, or allowed to overwrite the other.

CI generates JSON Schema B from TypeSpec only into `.typespec-json-schema-validator/generated/`, validates both JSON Schema lanes as Draft 2020-12, compares top-level declarations and normalized semantics, and executes bidirectional instance probes. The generated witness and deterministic receipt are evidence only.

A passing fixture proves this repository executes the fail-closed gate. It does not move Fiducia product schema ownership into the clients repository and does not certify unrelated client contracts. Canonical product authorities remain in `fiducia-cloud/fiducia-interfaces`; any unexplained mismatch stops evaluation and blocks promotion.
