# Fiducia client (Kotlin/JVM)

Thin Kotlin/JVM HTTP client for [fiducia.cloud](https://fiducia.cloud) (JDK 11+): `java.net.http.HttpClient` for transport, kotlinx-serialization-json for bodies (endpoints return `JsonElement`). Implements the shared `PROTOCOL.md` contract.

- `src/main/kotlin/cloud/fiducia/Fiducia.kt` — the client source.
- `build.gradle.kts` / `settings.gradle.kts` — Gradle build and Maven Central publishing (mirrors the Java sibling); `publish.sh` is the build/validate/release entrypoint; `LICENSE.txt` covers the package.
