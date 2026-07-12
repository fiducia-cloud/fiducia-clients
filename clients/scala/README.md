# Fiducia (Scala)

Fiducia HTTP client for Scala / JVM applications (JDK 11+). Transport is
`java.net.http.HttpClient`; JSON is `com.lihaoyi ujson` (the only dependency).
Cross-built for Scala 2.13 and 3.x. Implements the shared `PROTOCOL.md`
contract.

- `src/main/scala/cloud/fiducia/Fiducia.scala` — the `FiduciaClient` source.
- `build.sbt` / `project/` — sbt build and Maven Central publish config.
- `publish.sh` — `sbt +publish` cross-release entrypoint (see
  `clients/PUBLISHING.md`).
