# templates

Language templates consumed by `generate.py`: each `<lang>.<ext>.tmpl` is the
skeleton the generator fills from `operations.json` (the protocol's method
table) to produce that language's client under `clients/<lang>/`. Regenerate
rather than hand-editing generated output; template changes affect every
generated client, so run `generate_test.py` after touching one.
