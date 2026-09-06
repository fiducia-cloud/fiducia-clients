# Generated Dart publication unit

Files in this directory are derived from two reviewed inputs:

1. `operations.json`, the authored HTTP-operation contract; and
2. `clients/dart/fiducia.dart`, the reviewed transport and ergonomic client implementation.

Run `python3 generate_dart.py` from the repository root, then format with the CI-pinned Dart SDK. Do not edit generated Dart code directly. A change is admissible only when the generated-client workflow records the exact input and output SHA-256 digests, confirms every manifest operation has a Dart method, analyzes the candidate, and completes a pub.dev dry run.

The generated output is publication evidence and implementation code. It does not replace either TypeSpec or authored JSON Schema authority, nor does it change `operations.json`.
