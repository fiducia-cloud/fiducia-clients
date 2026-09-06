# Generated Dart publication evidence

The complete Dart publication unit is derived from two reviewed inputs:

1. `operations.json`, the authored HTTP-operation contract; and
2. `clients/dart/fiducia.dart`, the reviewed transport and ergonomic client implementation.

Generated Dart source is not hand-edited or treated as an authority. The exact candidate is produced in a temporary directory by `clients/dart/prepublish.sh`, formatted and analyzed with Dart, checked against the repository surface contract, and then used by `clients/dart/publish.sh`. CI also retains the candidate and a receipt containing the input and output SHA-256 digests.

Run the repository-root `generate_dart.py` only through the reviewed prepublish or CI path. Change `operations.json` or the reviewed Dart source, never a generated candidate. Generated output does not replace either TypeSpec or authored JSON Schema authority.
