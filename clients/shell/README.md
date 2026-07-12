# Fiducia (shell)

POSIX-shell Fiducia client requiring only `curl` and `jq`. Source `fiducia.sh`
and call its functions; each prints the JSON response to stdout. Supports
blocking and non-blocking lock helpers, retries, and timeouts via environment
variables. Implements the shared `PROTOCOL.md` contract.

- `fiducia.sh` — the client functions.
- `publish.sh` — syntax-check and tag/GitHub-release the script (see
  `clients/PUBLISHING.md`).
