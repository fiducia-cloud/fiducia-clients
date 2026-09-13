import 'fiducia.dart';

void main() {
  final client = FiduciaClient(
    'http://127.0.0.1',
    requestTimeout: const Duration(seconds: 5),
    lockRequestTimeout: const Duration(seconds: 9),
    retryMax: 2,
    retryDelay: const Duration(milliseconds: 15),
  );
  _expect(
      client.requestTimeout == const Duration(seconds: 5), 'requestTimeout');
  _expect(
    client.lockRequestTimeout == const Duration(seconds: 9),
    'lockRequestTimeout',
  );
  _expect(client.retryMax == 2, 'retryMax');
  _expect(client.retryDelay == const Duration(milliseconds: 15), 'retryDelay');
  client.close();
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError('fiducia options: $message');
  }
}
