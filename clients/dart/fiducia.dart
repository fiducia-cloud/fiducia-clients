// Fiducia HTTP client (Dart). Zero-dependency — dart:io + dart:convert.
// Implements PROTOCOL.md.
//
//   final c = FiduciaClient("https://api.fiducia.cloud");
//   final lock = await c.lock(["orders/checkout"], ttlMs: 30000); // blocks
//   await lock.release();
//   // non-blocking: final l = await c.tryLock(["orders/checkout"]); await l?.release();

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

class FiduciaException implements Exception {
  final int status;
  final dynamic body;
  FiduciaException(this.status, this.body);
  @override
  String toString() => 'fiducia: HTTP $status';
}

/// Thrown by the blocking [FiduciaClient.lock] / [FiduciaClient.acquireSemaphore]
/// when the wait budget elapses before acquisition.
class LockTimeoutException implements Exception {
  final List<String> keys;
  final int waitedMs;
  LockTimeoutException(this.keys, this.waitedMs);
  @override
  String toString() => 'fiducia: timed out after ${waitedMs}ms waiting for ${keys.join(", ")}';
}

/// A held lock grant. Call [release] (alias [unlock]) when done.
class Lock {
  final FiduciaClient _c;
  final List<String> keys;
  final String holder;
  final int fencingToken;
  final int? leaseExpiresMs;
  Lock(this._c, this.keys, this.holder, this.fencingToken, this.leaseExpiresMs);
  Future<dynamic> release() => _c.lockRelease(holder, fencingToken);
  Future<dynamic> unlock() => release();
}

/// A held semaphore permit. Call [release] when done.
class SemaphoreHandle {
  final FiduciaClient _c;
  final String key;
  final String holder;
  final int fencingToken;
  final int? leaseExpiresMs;
  SemaphoreHandle(this._c, this.key, this.holder, this.fencingToken, this.leaseExpiresMs);
  Future<dynamic> release() => _c.semaphoreRelease(key, holder, fencingToken);
  Future<dynamic> unlock() => release();
}

class FiduciaClient {
  final String base;
  final HttpClient _http = HttpClient();

  FiduciaClient(String baseUrl) : base = baseUrl.replaceAll(RegExp(r'/+$'), '');

  Future<dynamic> _request(String method, String path, [Object? body]) async {
    final req = await _http.openUrl(method, Uri.parse(base + path));
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    final data = text.isNotEmpty ? jsonDecode(text) : null;
    if (res.statusCode >= 300) throw FiduciaException(res.statusCode, data);
    return data;
  }

  String _enc(String s) => Uri.encodeComponent(s);

  // --- misc ---
  Future<dynamic> health() => _request('GET', '/healthz');
  Future<dynamic> status() => _request('GET', '/v1/status');

  // --- locks (current protocol: holder + fencing_token, key in the body) ---
  Future<dynamic> lockGet(String key) => _request('GET', '/v1/locks?key=${_enc(key)}');
  Future<dynamic> lockAcquire(List<String> keys, {String? holder, int? ttlMs, bool wait = false}) =>
      _request('POST', '/v1/locks/acquire', {'keys': keys, 'holder': holder, 'ttl_ms': ttlMs, 'wait': wait});
  Future<dynamic> lockRelease(String holder, int fencingToken) =>
      _request('POST', '/v1/locks/release', {'holder': holder, 'fencing_token': fencingToken});

  // --- semaphores ---
  Future<dynamic> semaphoreGet(String key) => _request('GET', '/v1/semaphores?key=${_enc(key)}');
  Future<dynamic> semaphoreAcquire(String key, int limit, {String? holder, int? ttlMs, bool wait = false}) =>
      _request('POST', '/v1/semaphores/acquire',
          {'key': key, 'limit': limit, 'holder': holder, 'ttl_ms': ttlMs, 'wait': wait});
  Future<dynamic> semaphoreRelease(String key, String holder, int fencingToken) =>
      _request('POST', '/v1/semaphores/release', {'key': key, 'holder': holder, 'fencing_token': fencingToken});

  // --- high-level blocking / try acquisition (live-mutex style) ---

  /// Take the union of [keys] now (wait:false). Returns null if held.
  Future<Lock?> tryLock(List<String> keys, {int ttlMs = 60000, String? holder}) =>
      _acquireLock(keys, false, ttlMs, holder, 0, 0, null);

  /// Block until [keys] are acquired, the budget elapses ([LockTimeoutException]),
  /// or the server errors (wait:true).
  Future<Lock> lock(List<String> keys,
      {int ttlMs = 60000, String? holder, int maxWaitMs = 30000, int retryIntervalMs = 250, int? maxRetries}) async {
    final got = await _acquireLock(keys, true, ttlMs, holder, maxWaitMs, retryIntervalMs, maxRetries);
    if (got == null) throw LockTimeoutException(keys, maxWaitMs);
    return got;
  }

  /// Alias of [lock] — blocks until acquired (or throws).
  Future<Lock> mustLock(List<String> keys,
          {int ttlMs = 60000, String? holder, int maxWaitMs = 30000, int retryIntervalMs = 250, int? maxRetries}) =>
      lock(keys, ttlMs: ttlMs, holder: holder, maxWaitMs: maxWaitMs, retryIntervalMs: retryIntervalMs, maxRetries: maxRetries);

  /// Take a permit now (wait:false). Returns null if at capacity.
  Future<SemaphoreHandle?> trySemaphore(String key, int limit, {int ttlMs = 60000, String? holder}) =>
      _acquireSemaphore(key, limit, false, ttlMs, holder, 0, 0, null);

  /// Block until a permit is free, the budget elapses, or the server errors.
  Future<SemaphoreHandle> acquireSemaphore(String key, int limit,
      {int ttlMs = 60000, String? holder, int maxWaitMs = 30000, int retryIntervalMs = 250, int? maxRetries}) async {
    final got = await _acquireSemaphore(key, limit, true, ttlMs, holder, maxWaitMs, retryIntervalMs, maxRetries);
    if (got == null) throw LockTimeoutException([key], maxWaitMs);
    return got;
  }

  Future<Lock?> _acquireLock(List<String> keys, bool wait, int ttlMs, String? holder,
      int maxWaitMs, int retryIntervalMs, int? maxRetries) async {
    holder ??= _genHolder();
    final out = _output(await lockAcquire(keys, holder: holder, ttlMs: ttlMs, wait: wait));
    if (out['acquired'] == true) {
      return Lock(this, keys, holder, _asInt(out['fencing_token']), _asIntOrNull(out['lease_expires_ms']));
    }
    if (!wait) return null; // tryLock: held now -> fail fast

    final deadline = DateTime.now().millisecondsSinceEpoch + maxWaitMs;
    var attempts = 0;
    while (maxRetries == null || attempts < maxRetries) {
      attempts++;
      final remaining = deadline - DateTime.now().millisecondsSinceEpoch;
      if (remaining <= 0) break;
      await Future<void>.delayed(Duration(milliseconds: min(retryIntervalMs, remaining)));
      final lk = (await lockGet(keys[0]))?['lock'];
      if (lk != null && lk['holder'] == holder && lk['fencing_token'] != null) {
        return Lock(this, keys, holder, _asInt(lk['fencing_token']), _asIntOrNull(lk['lease_expires_ms']));
      }
    }
    return null;
  }

  Future<SemaphoreHandle?> _acquireSemaphore(String key, int limit, bool wait, int ttlMs, String? holder,
      int maxWaitMs, int retryIntervalMs, int? maxRetries) async {
    holder ??= _genHolder();
    final out = _output(await semaphoreAcquire(key, limit, holder: holder, ttlMs: ttlMs, wait: wait));
    if (out['acquired'] == true) {
      return SemaphoreHandle(this, key, holder, _asInt(out['fencing_token']), _asIntOrNull(out['lease_expires_ms']));
    }
    if (!wait) return null;

    final deadline = DateTime.now().millisecondsSinceEpoch + maxWaitMs;
    var attempts = 0;
    while (maxRetries == null || attempts < maxRetries) {
      attempts++;
      final remaining = deadline - DateTime.now().millisecondsSinceEpoch;
      if (remaining <= 0) break;
      await Future<void>.delayed(Duration(milliseconds: min(retryIntervalMs, remaining)));
      final sem = (await semaphoreGet(key))?['semaphore'];
      final holders = (sem?['holders'] as List?) ?? const [];
      for (final h in holders) {
        if (h['holder'] == holder && h['fencing_token'] != null) {
          return SemaphoreHandle(this, key, holder, _asInt(h['fencing_token']), _asIntOrNull(h['lease_expires_ms']));
        }
      }
    }
    return null;
  }

  Map<String, dynamic> _output(dynamic resp) {
    final r = (resp is Map) ? resp['result'] : null;
    final o = (r is Map) ? r['output'] : null;
    return (o is Map) ? o.cast<String, dynamic>() : <String, dynamic>{};
  }

  int _asInt(dynamic v) => (v is num) ? v.toInt() : 0;
  int? _asIntOrNull(dynamic v) => (v is num) ? v.toInt() : null;
  String _genHolder() =>
      'fdc-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-${Random().nextInt(1 << 32).toRadixString(16)}';

  // --- reader-writer locks ---
  Future<dynamic> rwAcquireRead(String key, {int? ttlMs, bool wait = true}) =>
      _request('POST', '/v1/rw/${_enc(key)}/read', {'ttl_ms': ttlMs, 'wait': wait});
  Future<dynamic> rwEndRead(String key, String lockId) =>
      _request('POST', '/v1/rw/${_enc(key)}/read/end', {'lock_id': lockId});
  Future<dynamic> rwAcquireWrite(String key, {int? ttlMs, bool wait = true}) =>
      _request('POST', '/v1/rw/${_enc(key)}/write', {'ttl_ms': ttlMs, 'wait': wait});
  Future<dynamic> rwEndWrite(String key, String lockId) =>
      _request('POST', '/v1/rw/${_enc(key)}/write/end', {'lock_id': lockId});

  // --- config KV ---
  Future<dynamic> kvGet(String key) => _request('GET', '/v1/kv/${_enc(key)}');
  Future<dynamic> kvPut(String key, String value, {int? ttlMs}) =>
      _request('PUT', '/v1/kv/${_enc(key)}', {'value': value, 'ttl_ms': ttlMs});
  Future<dynamic> kvDelete(String key) => _request('DELETE', '/v1/kv/${_enc(key)}');
  Future<dynamic> kvList(String prefix) => _request('GET', '/v1/kv?prefix=${_enc(prefix)}');

  // --- leader election ---
  Future<dynamic> electionCampaign(String name, String candidate, int ttlMs) =>
      _request('POST', '/v1/elections/${_enc(name)}/campaign', {'candidate': candidate, 'ttl_ms': ttlMs});
  Future<dynamic> electionRenew(String name, String candidate, int fencingToken) =>
      _request('POST', '/v1/elections/${_enc(name)}/renew', {'candidate': candidate, 'fencing_token': fencingToken});
  Future<dynamic> electionResign(String name, String candidate, int fencingToken) =>
      _request('POST', '/v1/elections/${_enc(name)}/resign', {'candidate': candidate, 'fencing_token': fencingToken});
  Future<dynamic> electionGet(String name) => _request('GET', '/v1/elections/${_enc(name)}');

  // --- service discovery ---
  Future<dynamic> serviceRegister(String service, String instanceId, String address, int ttlMs) =>
      _request('PUT', '/v1/services/${_enc(service)}/instances/${_enc(instanceId)}', {'address': address, 'ttl_ms': ttlMs});
  Future<dynamic> serviceHeartbeat(String service, String instanceId) =>
      _request('POST', '/v1/services/${_enc(service)}/instances/${_enc(instanceId)}/heartbeat');
  Future<dynamic> serviceDeregister(String service, String instanceId) =>
      _request('DELETE', '/v1/services/${_enc(service)}/instances/${_enc(instanceId)}');
  Future<dynamic> serviceInstances(String service) => _request('GET', '/v1/services/${_enc(service)}');
  Future<dynamic> serviceList() => _request('GET', '/v1/services');
}
