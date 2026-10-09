# Draft Oreslang client conformance target

**Current status: proposed; no Oreslang SDK or conformance claimed.**

Repo `fiducia-cloud/fiducia-clients` existing paths: `clients/`, `contracts/`, `contract/`, `schemas/`, `governance/`.
Do not replace these peer-authority inputs or bypass governance.

## Contract-preserving implementation

1. Identify the exact immutable TypeSpec and independently authored JSON Schema
   Draft 2020-12 pair in the paired `*-interfaces` authority repository.
   Record exact source SHA and SHA-256 digest; generated outputs are only evidence.
2. Generate an Oreslang declaration header through the shared
   `ORESoftware/ores-clients-core` Oreslang renderer (draft PR #11),
   then implement/compile the actual client. Keep Fiducia public/private client scope, RPC boundaries and governing participant matrix.
3. Run TJSV current-input peer parity and Contract IR admission before
   testing runtime adapters. Execute both valid and invalid fixture corpora
   using native Oreslang on JVM/GraalVM. Verify ingress and egress behavior,
   with positive/negative inputs, null-vs-absent, bounds, union tags and
   typed error envelopes. Compare canonical JSON against other languages.
4. Produce TJSV language/runtime boundary evidence bound to exact head SHA,
   source closure, fixture input digests, compiler identity and received
   artifact digest. Missing/unknown/failed evidence must block promotion.
5. Track browser JS and Wasm as **separate future** targets; each requires
   compiler, browser sandbox/capability and differential conformance tests.
6. Admit Oreslang into language participant/governance and client-target
   manifests **only after** executable CI and actual package tests exist.

## Blocked acceptance criteria

No release, language-support advertising or mandatory participant registration
until the Oreslang compiler test, schema parity, positive and negative corpus,
and exact-head CI all succeed. This file is an admission plan, not runtime proof.
