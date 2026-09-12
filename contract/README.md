# Exported-interface contract

This directory is the enforced answer to a question a polyglot SDK repo cannot
answer by inspection: **do all N language clients actually expose the same
interface?**

## Two layers, and why

| File | What it is | What validates it |
|---|---|---|
| `surface.contract.json` | The declaration. Every operation each client must export, its parameters, its error types, and per-language naming. | `surface.schema.json` |
| `surface.schema.json` | A JSON Schema 2020-12 meta-schema. | Any JSON Schema validator; editors use it for completion via `$schema`. |

JSON Schema validates *JSON data*, so pointing it straight at "an SDK's exported
functions" is a category error. The split above puts it where it belongs: the
contract is a JSON document (so JSON Schema validates it rigorously, and your
editor autocompletes it), and a checker enforces that document against real
source. Request and response bodies — genuine JSON data — are ordinary JSON
Schema subschemas under `types`, and in repos with a paired `*-interfaces` repo
they reference the schemas that already live there.

## Enforcement

```sh
python3 contract/bin/check_surface.py                    # everything
python3 contract/bin/check_surface.py --lang go          # one client
python3 contract/bin/check_surface.py --prepublish --lang go
python3 contract/bin/check_surface.py --schema-only      # just validate the doc
python3 contract/bin/check_surface.py --format github    # CI annotations
```

Python 3.8+, standard library only. No toolchain for the language being checked
is required, which is the whole point: a gate that needs 30 SDK toolchains
installed is a gate that gets switched off. If the `jsonschema` package happens
to be installed it is used for meta-validation; otherwise the bundled
`jsonschema_mini.py` subset validator runs.

Wired into three places:

- **tests** — `clients/<lang>` test hooks, so a contract break fails locally
- **CI** — `.github/workflows/surface-contract.yml`
- **pre-publish** — `contract/bin/prepublish-guard.sh`, invoked from each
  `publish.sh`, so a drifted client cannot reach a package registry

## Tiers, and the ratchet

Each language carries a `tier`:

- `gate` — violations fail CI and block publish.
- `warn` — reported, non-blocking. For clients that are deliberately partial.
- `off` — skipped.

Tiers were assigned by measurement at adoption, not aspiration: a language was
promoted to `gate` only if it conformed on the day the contract landed. That is
what makes the gate meaningful instead of permanently red.

`warn` is not a hole, because every language also carries **`minCoverage`** — the
percentage it exported at adoption. Dropping below that floor is an error **at
every tier**. A partial client may stay partial; it may not quietly get worse.
As a client fills in, raise its `minCoverage`, and when it reaches 100 move it to
`gate`.

## Waivers

An operation may be absent from a language only via a `waiver`, which must carry
a `reason` and an `expires` date. **An expired waiver fails the build at every
tier.** This is deliberate: exemptions that cannot rot are the only kind worth
having.

`optionalIn` is the narrower escape hatch, for operations that are genuinely
inapplicable to a target (a filesystem call in a wasm client) rather than merely
unimplemented.

## Changing the contract

Editing `surface.contract.json` changes what every client must do, so treat it
like an API change:

- adding an operation → MINOR `contractVersion` bump
- renaming or removing one → MAJOR bump
- never edit it to make a red build green; that inverts the entire point

If the repo has a `provenance.source` (usually `operations.json`, or the paired
`*-interfaces` repo), its sha256 is recorded here and checked on every run, so
the upstream manifest and this contract cannot drift apart unnoticed. Refresh
with:

```sh
python3 contract/bin/derive_contract.py --repo . --product <slug> \
    --from-operations operations.json --stats
```

and review the resulting diff rather than committing it blind.
