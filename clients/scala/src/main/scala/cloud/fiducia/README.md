# cloud.fiducia package

`Fiducia.scala` — the entire Scala client in the `cloud.fiducia` package:
`FiduciaClient` (built on `java.net.http.HttpClient` + `ujson`) with one method
per `PROTOCOL.md` operation, plus the `FiduciaError` thrown on HTTP status ≥ 300.
The package path mirrors the `cloud.fiducia` Maven coordinates.
