# Fiducia client (PHP)

Zero-dependency PHP HTTP client for [fiducia.cloud](https://fiducia.cloud): only `ext-curl` and `json`, no third-party packages. Implements the shared `PROTOCOL.md` contract.

- `Fiducia.php` — the client (namespace `Fiducia`, class `Client`); throws `FiduciaException` on HTTP status >= 300.
- `composer.json` — package metadata; `publish.sh` is the build/validate/release entrypoint.
