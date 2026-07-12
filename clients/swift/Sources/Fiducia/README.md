# Fiducia target sources

`Fiducia.swift` — the entire `Fiducia` Swift Package Manager target. A
zero-dependency `FiduciaClient` on Foundation's `URLSession` +
`JSONSerialization`, with one `async` method per `PROTOCOL.md` operation, plus
`FiduciaError` (HTTP status ≥ 300) and `FiduciaTimeout` (blocking wait budget
elapsed). See the client's `../../README.md` for install and usage.
