import 'dart:convert';
import 'dart:io';

import 'fiducia.dart';

Future<void> main() async {
  final requests = <HttpRequest>[];
  final bodies = <Map<String, Object?>>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    requests.add(request);
    if (request.method == 'POST') {
      final text = await utf8.decoder.bind(request).join();
      bodies.add(Map<String, Object?>.from(jsonDecode(text) as Map));
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({'id': 'operation-7', 'committed_version': 4}),
      );
    } else {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'changes': [
            {
              'sequence': 41,
              'table': 'infra_operations',
              'op': 'upsert',
              'id': 'operation-7',
              'version': 4,
              'row': {'state': 'running'},
            },
          ],
          'next_cursor': 41,
          'has_more': false,
        }),
      );
    }
    await request.response.close();
  });

  final client = FiduciaClient(
    'http://${server.address.address}:${server.port}',
  );
  try {
    final send = client.syncSender(pathPrefix: '/api/admin/sync');
    final acknowledgement = await send({
      'id': 'operation-7',
      'table': 'infra_operations',
      'op': 'upsert',
      'payload': {'state': 'queued'},
      'base_version': 3,
      'key': 'write-operation-7-v4',
      'write_policy': {
        'strategy': 'pessimistic',
        'failure_mode': 'throw_error',
        'telemetry': 'lifecycle',
      },
    });
    _expect(acknowledgement['committed_version'] == 4, 'ack version');
    _expect(
      requests.first.headers.value('idempotency-key') == 'write-operation-7-v4',
      'durable idempotency key',
    );
    _expect(
      jsonEncode(bodies.single) ==
          jsonEncode({
            'id': 'operation-7',
            'table': 'infra_operations',
            'op': 'upsert',
            'payload': {'state': 'queued'},
            'base_version': 3,
            'key': 'write-operation-7-v4',
          }),
      'canonical body',
    );

    final pull = client.syncPuller(
      'infra_operations',
      pathPrefix: '/api/admin/sync',
    );
    final page = await pull(40, 2);
    final change = (page['changes'] as List).single as Map<String, Object?>;
    _expect(page['next_cursor'] == 41, 'next cursor');
    _expect(change['at_ms'] == 0, 'normalized timestamp');
    _expect(change['sync_sequence'] == 41, 'normalized sequence');
    _expect(!change.containsKey('sequence'), 'legacy sequence removed');
  } finally {
    client.close();
    await server.close(force: true);
  }
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError('failed: $message');
}
