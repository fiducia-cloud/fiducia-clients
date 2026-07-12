# Fiducia (Python)

Zero-dependency (stdlib `urllib`) Python client, CLI, and test suites for
fiducia.cloud. Implements the shared `PROTOCOL.md` contract.

- `fiducia.py` — the thin client, generated from `operations.json` by
  `generate.py` (do not edit by hand).
- `locking.py` — hand-written live-mutex-style ergonomics (`try_lock`,
  `must_lock`, semaphores) layered on the generated client.
- `cli.py` — the `fiducia` coordination CLI; drives the SDK, never speaks HTTP
  directly.
- `fiducia_test.py` — offline unit tests. `live_tests.py`, `feature_tests.py`,
  `resilience_tests.py`, `auth_e2e.py` — integration tests run through the SDK
  against a deployed cluster.
- `pyproject.toml` / `publish.sh` — packaging manifest and PyPI release
  entrypoint (see `clients/PUBLISHING.md`).
