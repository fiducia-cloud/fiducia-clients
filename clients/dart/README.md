# fiducia_client

Fiducia HTTP client for Dart applications.

```dart
import 'package:fiducia_client/fiducia_client.dart';

final client = FiduciaClient('https://api.fiducia.cloud');
```

The dependency-free JSON sync methods compose with the strongly typed
`fiducia_sync` Flutter package through its adapters:

```dart
final send = adaptJsonSender(
  client.syncSender(pathPrefix: '/api/admin/sync'),
);
final pull = adaptJsonPuller(
  client.syncPuller('infra_operations', pathPrefix: '/api/admin/sync'),
);
```

`syncSender()` sends the durable queued-write key as `Idempotency-Key`.
`syncPuller()` returns ordered cursor pages and normalizes the legacy admin
service `sequence` field to the canonical `sync_sequence` field.
