// Fiducia HTTP client (Dart). Zero-dependency — dart:io + dart:convert.
// Implements PROTOCOL.md.
//
//   final c = FiduciaClient("https://api.fiducia.cloud");
//   final lock = await c.lockAcquire("orders/checkout", ttlMs: 30000);
//   await c.lockRelease("orders/checkout", lock["result"]["lock_id"]);

import 'dart:convert';
import 'dart:io';

class FiduciaException implements Exception {
  final int status;
  final dynamic body;
  FiduciaException(this.status, this.body);
  @override
  String toString() => 'fiducia: HTTP $status';
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

  // --- locks & semaphores ---
  Future<dynamic> lockAcquire(String key, {int? ttlMs, bool wait = true, int max = 1}) =>
      _request('POST', '/v1/locks/${_enc(key)}/acquire', {'ttl_ms': ttlMs, 'wait': wait, 'max': max});
  Future<dynamic> lockRelease(String key, String lockId) =>
      _request('POST', '/v1/locks/${_enc(key)}/release', {'lock_id': lockId});

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
  Future<dynamic> kvGet(String key) => _request('GET', '/v1/kv?key=${_enc(key)}');
  Future<dynamic> kvPut(String key, String value, {int? ttlMs}) =>
      _request('PUT', '/v1/kv?key=${_enc(key)}', {'value': value, 'ttl_ms': ttlMs});
  Future<dynamic> kvDelete(String key) => _request('DELETE', '/v1/kv?key=${_enc(key)}');
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
