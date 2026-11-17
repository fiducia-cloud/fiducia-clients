# Oreslang contract and runtime admission (draft)

**Status: NOT ADMITTED.** This tracks proposed Oreslang support without claiming a functioning SDK or changing authored types.

- Repo role: clients; contract owner: [fiducia-cloud/fiducia-interfaces](https://github.com/fiducia-cloud/fiducia-interfaces).
- Source inventory: operations.json, contracts/, schemas/. Resolve exact reviewed paths and immutable revisions before generating anything.
- Product invariants: Fiducia authentication and token handling, bounded errors, source revision pinning, and production security gates must remain intact.

## Fail-closed implementation requirements

1. TypeSpec and JSON Schema Draft 2020-12 are independent human-authored peers. Locate and pin **both**, identify missing/partial product coverage, and never generate one peer to certify the other.
2. Use [TJSV](https://github.com/ORESoftware/typespec-json-schema-validator) for cross-authority parity, current-input Contract IR, fixture binding and final Oreslang runtime-admission decision. [ores-contracts](https://github.com/ORESoftware/ores-contracts) adds separate deterministic persistence witnesses only for its supported subset.
3. Implement an Oreslang SDK/adapter from admitted declarations, using the real [Oreslang GraalVM compiler](https://github.com/ores-truffle-oreslang/oreslang-source.java) and [Oreslang serialization/validation](https://github.com/ores-truffle-oreslang/oreslang-serialization-and-validation). Never hand-edit generated outputs or assert a stub/compiler-launcher check proves semantic conformance.
4. Run the owner-reviewed valid/invalid/boundary/replay corpus, including null vs absent, enums, exact integer widths, unknown fields, errors, limits and protocol versions. Reject missing features/toolchains rather than skip.
5. Emit bounded payload-free adapter verdicts tied to current Contract IR ID, parity receipt, fixture digest, implementation revision and exact compiler pin. Test a real external consumer and Zed publication/package contents.
6. Oreslang→JavaScript and Oreslang→Wasm/browser are future separate target lanes. Do not mark browser support green until the Oreslang compiler emits artifacts that execute under hermetic browser tests.

- [ ] Independently authored peers checked
- [ ] Exact-source TJSV/Contract IR admission
- [ ] Real Oreslang native positive and negative tests
- [ ] External consumer and package artifact pass

Nothing here certifies or enables a runtime today. This is deliberately a draft admission specification, not contract or client implementation.
