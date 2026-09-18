import 'dart:convert';
import 'dart:io';

import 'fiducia.dart';

Future<void> main() async {
  final seen = <(String, String)>[]; // (method, uri)
  final putBodies = <Map<String, Object?>>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final uri = request.uri.toString();
    seen.add((request.method, uri));
    request.response.headers.contentType = ContentType.json;
    if (request.method == 'PUT') {
      final text = await utf8.decoder.bind(request).join();
      putBodies.add(Map<String, Object?>.from(jsonDecode(text) as Map));
      request.response.write(jsonEncode({'mod_revision': 4}));
    } else if (request.method == 'DELETE') {
      request.response.write(jsonEncode({'deleted': true}));
    } else if (uri.contains('prefix=')) {
      // A list: the store DOES return values; the client must strip them.
      request.response.write(
        jsonEncode({
          'prefix': 'secret/',
          'count': 2,
          'keys': [
            {
              'key': 'secret/api-key',
              'value': 'LEAK-1',
              'mod_revision': 2,
              'expires_at_ms': 111,
              'protection': {'at_rest': 'encrypted'},
            },
            {'key': 'secret/db/password', 'value': 'LEAK-2', 'mod_revision': 4},
          ],
        }),
      );
    } else {
      // A reveal.
      request.response.write(
        jsonEncode({
          'key': 'secret/api-key',
          'found': true,
          'entry': {'value': 'sk-live-xyz', 'mod_revision': 2},
        }),
      );
    }
    await request.response.close();
  });

  final client = FiduciaClient(
    'http://${server.address.address}:${server.port}',
  );
  try {
    // put: reserved namespace + always encrypted.
    final put = await client.secretPut(
      'db/password',
      'hunter2',
      ttlMs: 60000,
      prevRevision: 0,
    );
    _expect(put['mod_revision'] == 4, 'put ack');
    _expect(seen.last.$1 == 'PUT', 'put method');
    _expect(seen.last.$2 == '/v1/kv?key=secret%2Fdb%2Fpassword', 'put key');
    _expect(putBodies.single['value'] == 'hunter2', 'put value');
    _expect(putBodies.single['plaintext'] == false, 'secrets never plaintext');
    _expect(putBodies.single['prev_revision'] == 0, 'put CAS guard');

    // list: names + metadata only, values stripped, prefix removed.
    final list = await client.secretList();
    _expect(seen.last.$2 == '/v1/kv?prefix=secret%2F', 'list prefix');
    _expect(list['count'] == 2, 'list count');
    final secrets = list['secrets'] as List;
    _expect((secrets[0] as Map)['name'] == 'api-key', 'stripped name');
    _expect((secrets[1] as Map)['name'] == 'db/password', 'nested name');
    _expect(!jsonEncode(list).contains('LEAK'), 'list never leaks a value');

    // reveal: the only value path.
    final revealed = await client.secretReveal('api-key');
    _expect(
      (revealed['entry'] as Map)['value'] == 'sk-live-xyz',
      'reveal value',
    );
    _expect(seen.last.$2 == '/v1/kv?key=secret%2Fapi-key', 'reveal key');

    // delete.
    await client.secretDelete('api-key');
    _expect(seen.last.$1 == 'DELETE', 'delete method');

    // empty names are rejected before any request.
    final before = seen.length;
    var threw = false;
    try {
      await client.secretPut('', 'v');
    } on ArgumentError {
      threw = true;
    }
    _expect(threw, 'empty name rejected');
    _expect(seen.length == before, 'no request for empty name');

    print('fiducia_secrets_test: all assertions passed');
  } finally {
    client.close();
    await server.close(force: true);
  }
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError('failed: $message');
}
