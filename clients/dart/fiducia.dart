// Fiducia HTTP client (Dart). Zero-dependency — dart:io + dart:convert.
// Implements PROTOCOL.md.
//
//   final c = FiduciaClient("https://api.fiducia.cloud");
//   final lock = await c.lockAcquire("orders/checkout", ttlMs: 30000);
//   await c.lockRelease("orders/checkout", "worker-a", lock["result"]["output"]["fencing_token"]);

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

class FiduciaRequestOptions {
  final Duration? timeout;
  final Duration? requestTimeout;
  final Duration? lockRequestTimeout;
  final int maxRetries;
  final int retryMax;
  final int retries;
  final Duration retryDelay;

  const FiduciaRequestOptions({
    this.timeout,
    this.requestTimeout,
    this.lockRequestTimeout,
    this.maxRetries = 0,
    this.retryMax = 0,
    this.retries = 0,
    this.retryDelay = Duration.zero,
  });
}

class FiduciaClient {
  final String base;
  final HttpClient _http = HttpClient();
  Duration? requestTimeout;
  Duration? lockRequestTimeout;
  int retryMax = 0;
  Duration retryDelay = Duration.zero;

  FiduciaClient(String baseUrl) : base = baseUrl.replaceAll(RegExp(r'/+$'), '');

  Future<dynamic> _request(
    String method,
    String path, [
    Object? body,
    FiduciaRequestOptions? options,
    bool lockAcquire = false,
  ]) async {
    final maxRetries = _resolveRetries(options);
    for (var attempt = 0; ; attempt++) {
      try {
        final timeout = _resolveTimeout(options, lockAcquire);
        final future = _requestOnce(method, path, body);
        return timeout == null ? await future : await future.timeout(timeout);
      } catch (e) {
        if (attempt >= maxRetries || !_retryable(e)) rethrow;
        final delay = _resolveRetryDelay(options);
        if (delay > Duration.zero) await Future<void>.delayed(delay);
      }
    }
  }

  Future<dynamic> _requestOnce(
    String method,
    String path, [
    Object? body,
  ]) async {
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

  Duration? _resolveTimeout(FiduciaRequestOptions? options, bool lockAcquire) =>
      options?.lockRequestTimeout ??
      options?.requestTimeout ??
      options?.timeout ??
      (lockAcquire ? lockRequestTimeout : null) ??
      requestTimeout;

  int _resolveRetries(FiduciaRequestOptions? options) {
    for (final value in [
      options?.maxRetries ?? 0,
      options?.retryMax ?? 0,
      options?.retries ?? 0,
      retryMax,
    ]) {
      if (value > 0) return value;
    }
    return 0;
  }

  Duration _resolveRetryDelay(FiduciaRequestOptions? options) =>
      options != null && options.retryDelay > Duration.zero
      ? options.retryDelay
      : retryDelay;

  bool _retryable(Object e) {
    if (e is FiduciaException) {
      return const [408, 425, 429, 500, 502, 503, 504].contains(e.status);
    }
    return e is IOException || e is TimeoutException;
  }

  String _enc(String s) => Uri.encodeComponent(s);

  // --- misc ---
  Future<dynamic> health() => _request('GET', '/healthz');
  Future<dynamic> status() => _request('GET', '/v1/status');

  // --- locks & semaphores ---
  Future<dynamic> lockAcquire(
    String key, {
    int? ttlMs,
    bool wait = true,
    int max = 1,
    FiduciaRequestOptions? options,
  }) => _lockAcquireWithWait(
    key,
    ttlMs: ttlMs,
    wait: wait,
    max: max,
    options: options,
  );
  Future<dynamic> tryLock(
    String key, {
    int? ttlMs,
    int max = 1,
    FiduciaRequestOptions? options,
  }) => _lockAcquireWithWait(
    key,
    ttlMs: ttlMs,
    wait: false,
    max: max,
    options: options,
  );
  Future<dynamic> mustLock(
    String key, {
    int? ttlMs,
    int max = 1,
    FiduciaRequestOptions? options,
  }) => _lockAcquireWithWait(
    key,
    ttlMs: ttlMs,
    wait: true,
    max: max,
    options: options,
  );
  Future<dynamic> lock(
    String key, {
    int? ttlMs,
    int max = 1,
    FiduciaRequestOptions? options,
  }) => mustLock(key, ttlMs: ttlMs, max: max, options: options);
  Future<dynamic> _lockAcquireWithWait(
    String key, {
    int? ttlMs,
    required bool wait,
    required int max,
    FiduciaRequestOptions? options,
  }) => _request(
    'POST',
    '/v1/locks/acquire',
    {'key': key, 'ttl_ms': ttlMs, 'wait': wait, 'max': max},
    options,
    true,
  );
  Future<dynamic> lockRelease(String key, String holder, int fencingToken) =>
      _request('POST', '/v1/locks/release', {'holder': holder, 'fencing_token': fencingToken});
  Future<dynamic> semaphoreAcquire(
    String key, {
    int? ttlMs,
    bool wait = true,
    int max = 2,
    FiduciaRequestOptions? options,
  }) => _semaphoreAcquireWithWait(
    key,
    ttlMs: ttlMs,
    wait: wait,
    max: max,
    options: options,
  );
  Future<dynamic> trySemaphore(
    String key, {
    int? ttlMs,
    int max = 2,
    FiduciaRequestOptions? options,
  }) => _semaphoreAcquireWithWait(
    key,
    ttlMs: ttlMs,
    wait: false,
    max: max,
    options: options,
  );
  Future<dynamic> mustSemaphore(
    String key, {
    int? ttlMs,
    int max = 2,
    FiduciaRequestOptions? options,
  }) => _semaphoreAcquireWithWait(
    key,
    ttlMs: ttlMs,
    wait: true,
    max: max,
    options: options,
  );
  Future<dynamic> semaphore(
    String key, {
    int? ttlMs,
    int max = 2,
    FiduciaRequestOptions? options,
  }) => mustSemaphore(key, ttlMs: ttlMs, max: max, options: options);
  Future<dynamic> _semaphoreAcquireWithWait(
    String key, {
    int? ttlMs,
    required bool wait,
    required int max,
    FiduciaRequestOptions? options,
  }) => _request(
    'POST',
    '/v1/semaphores/acquire',
    {'key': key, 'ttl_ms': ttlMs, 'wait': wait, 'limit': max < 2 ? 2 : max},
    options,
    true,
  );
  Future<dynamic> semaphoreRelease(String key, String holder, int fencingToken) => _request(
    'POST',
    '/v1/semaphores/release',
    {'key': key, 'holder': holder, 'fencing_token': fencingToken},
  );

  // --- reader-writer locks ---
  Future<dynamic> rwAcquireRead(String key, {int? ttlMs, bool wait = true}) =>
      _request('POST', '/v1/rw/${_enc(key)}/read', {
        'ttl_ms': ttlMs,
        'wait': wait,
      });
  Future<dynamic> rwEndRead(String key, String lockId) =>
      _request('POST', '/v1/rw/${_enc(key)}/read/end', {'lock_id': lockId});
  Future<dynamic> rwAcquireWrite(String key, {int? ttlMs, bool wait = true}) =>
      _request('POST', '/v1/rw/${_enc(key)}/write', {
        'ttl_ms': ttlMs,
        'wait': wait,
      });
  Future<dynamic> rwEndWrite(String key, String lockId) =>
      _request('POST', '/v1/rw/${_enc(key)}/write/end', {'lock_id': lockId});

  // --- config KV ---
  Future<dynamic> kvGet(String key) => _request('GET', '/v1/kv?key=${_enc(key)}');
  Future<dynamic> kvPut(String key, String value, {int? ttlMs}) =>
      _request('PUT', '/v1/kv?key=${_enc(key)}', {'value': value, 'ttl_ms': ttlMs});
  Future<dynamic> kvDelete(String key) =>
      _request('DELETE', '/v1/kv?key=${_enc(key)}');
  Future<dynamic> kvList(String prefix) =>
      _request('GET', '/v1/kv?prefix=${_enc(prefix)}');

  // --- leader election ---
  Future<dynamic> electionCampaign(String name, String candidate, int ttlMs) =>
      _request('POST', '/v1/elections/${_enc(name)}/campaign', {
        'candidate': candidate,
        'ttl_ms': ttlMs,
      });
  Future<dynamic> electionRenew(
    String name,
    String candidate,
    int fencingToken,
  ) => _request('POST', '/v1/elections/${_enc(name)}/renew', {
    'candidate': candidate,
    'fencing_token': fencingToken,
  });
  Future<dynamic> electionResign(
    String name,
    String candidate,
    int fencingToken,
  ) => _request('POST', '/v1/elections/${_enc(name)}/resign', {
    'candidate': candidate,
    'fencing_token': fencingToken,
  });
  Future<dynamic> electionGet(String name) =>
      _request('GET', '/v1/elections/${_enc(name)}');

  // --- service discovery ---
  Future<dynamic> serviceRegister(
    String service,
    String instanceId,
    String address,
    int ttlMs,
  ) => _request(
    'PUT',
    '/v1/services/${_enc(service)}/instances/${_enc(instanceId)}',
    {'address': address, 'ttl_ms': ttlMs},
  );
  Future<dynamic> serviceHeartbeat(String service, String instanceId) =>
      _request(
        'POST',
        '/v1/services/${_enc(service)}/instances/${_enc(instanceId)}/heartbeat',
      );
  Future<dynamic> serviceDeregister(String service, String instanceId) =>
      _request(
        'DELETE',
        '/v1/services/${_enc(service)}/instances/${_enc(instanceId)}',
      );
  Future<dynamic> serviceInstances(String service) =>
      _request('GET', '/v1/services/${_enc(service)}');
  Future<dynamic> serviceList() => _request('GET', '/v1/services');
}
