# Fiducia client (Java)

Zero-dependency Java HTTP client for [fiducia.cloud](https://fiducia.cloud) (JDK 11+): `java.net.http` for transport plus a tiny built-in JSON parser/serializer, so no third-party JSON library is needed. Implements the shared `PROTOCOL.md` contract.

- `Fiducia.java` — the client (package `cloud.fiducia`); every endpoint returns a `Map<String,Object>`.
- `pom.xml` — Maven build/publish config; `publish.sh` is the build/validate/release entrypoint; `LICENSE.txt` covers the package.
