# Fiducia (Python)

Zero-dependency (stdlib `urllib`) Python client, CLI, and test suites for
fiducia.cloud. Implements the shared `PROTOCOL.md` contract.

- `fiducia.py` — the production client and packaged CLI entry point, generated
  from `templates/python.py.tmpl` plus `operations.json` (do not edit by hand).
- `locking.py` — hand-written live-mutex-style ergonomics (`try_lock`,
  `must_lock`, semaphores) layered on the generated client.
- The packaged `fiducia` command is `fiducia:main` and uses
  `FIDUCIA_BASE_URL` / `FIDUCIA_TIMEOUT_SECONDS`. `cli.py` is a legacy developer
  command surface that uses `FIDUCIA_URL`; it is not the packaged entry point.
- `fiducia_test.py` — offline unit tests. `live_tests.py`, `feature_tests.py`,
  `resilience_tests.py`, `auth_e2e.py` — integration tests run through the SDK
  against a deployed cluster.
- `pyproject.toml` / `publish.sh` — packaging manifest and PyPI release
  entrypoint (see `clients/PUBLISHING.md`).

Neither CLI surface currently accepts a public bearer token or API key. Use
them only against an endpoint that intentionally allows unauthenticated access.
