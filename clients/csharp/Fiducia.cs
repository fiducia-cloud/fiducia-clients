// Fiducia HTTP client (C# / .NET). Uses HttpClient + System.Text.Json (built-in).
// Implements PROTOCOL.md.
//
//   var c = new Fiducia.FiduciaClient("https://api.fiducia.cloud");
//   var lock = await c.LockAcquire("orders/checkout", 30000);
//   await c.LockRelease("orders/checkout", "worker-a", lock.GetProperty("result").GetProperty("output").GetProperty("fencing_token").GetInt64());

#nullable enable

using System;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Fiducia
{
    public class FiduciaException : Exception
    {
        public int Status { get; }
        public string Body { get; }
        public FiduciaException(int status, string body) : base($"fiducia: HTTP {status}")
        {
            Status = status;
            Body = body;
        }
    }

    public class FiduciaClient
    {
        private readonly string _base;
        private static readonly HttpClient Http = new HttpClient();
        public TimeSpan? RequestTimeout { get; set; }
        public TimeSpan? LockRequestTimeout { get; set; }
        public int RetryMax { get; set; }
        public TimeSpan RetryDelay { get; set; } = TimeSpan.Zero;

        public FiduciaClient(string baseUrl) => _base = baseUrl.TrimEnd('/');

        public class RequestOptions
        {
            public TimeSpan? Timeout { get; set; }
            public TimeSpan? RequestTimeout { get; set; }
            public TimeSpan? LockRequestTimeout { get; set; }
            public int MaxRetries { get; set; }
            public int RetryMax { get; set; }
            public int Retries { get; set; }
            public TimeSpan RetryDelay { get; set; } = TimeSpan.Zero;
            public CancellationToken CancellationToken { get; set; } = CancellationToken.None;
        }

        private Task<JsonElement> Request(HttpMethod method, string path, object? body = null) =>
            Request(method, path, body, null, false);

        private async Task<JsonElement> Request(HttpMethod method, string path, object? body, RequestOptions? options, bool lockAcquire)
        {
            var maxRetries = ResolveRetries(options);
            for (var attempt = 0; ; attempt++)
            {
                try
                {
                    return await RequestOnce(method, path, body, options, lockAcquire);
                }
                catch (Exception ex)
                {
                    if (attempt >= maxRetries || options?.CancellationToken.IsCancellationRequested == true || !Retryable(ex))
                        throw;
                    var delay = ResolveRetryDelay(options);
                    if (delay > TimeSpan.Zero)
                        await Task.Delay(delay, options?.CancellationToken ?? CancellationToken.None);
                }
            }
        }

        private async Task<JsonElement> RequestOnce(HttpMethod method, string path, object? body, RequestOptions? options, bool lockAcquire)
        {
            using var req = new HttpRequestMessage(method, _base + path);
            if (body != null)
                req.Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");
            using var timeout = TimeoutSource(options, lockAcquire);
            var token = timeout?.Token ?? options?.CancellationToken ?? CancellationToken.None;
            var res = await Http.SendAsync(req, token);
            var text = await res.Content.ReadAsStringAsync();
            if ((int)res.StatusCode >= 300) throw new FiduciaException((int)res.StatusCode, text);
            return string.IsNullOrEmpty(text) ? default : JsonDocument.Parse(text).RootElement;
        }

        private CancellationTokenSource? TimeoutSource(RequestOptions? options, bool lockAcquire)
        {
            var timeout = options?.LockRequestTimeout ?? options?.RequestTimeout ?? options?.Timeout ??
                (lockAcquire ? LockRequestTimeout : null) ?? RequestTimeout;
            if (timeout == null) return null;
            var cts = CancellationTokenSource.CreateLinkedTokenSource(options?.CancellationToken ?? CancellationToken.None);
            cts.CancelAfter(timeout.Value);
            return cts;
        }

        private int ResolveRetries(RequestOptions? options)
        {
            if (options?.MaxRetries > 0) return options.MaxRetries;
            if (options?.RetryMax > 0) return options.RetryMax;
            if (options?.Retries > 0) return options.Retries;
            return Math.Max(RetryMax, 0);
        }

        private TimeSpan ResolveRetryDelay(RequestOptions? options) =>
            options != null && options.RetryDelay > TimeSpan.Zero ? options.RetryDelay : RetryDelay;

        private static bool Retryable(Exception ex)
        {
            if (ex is FiduciaException fe)
                return fe.Status == 408 || fe.Status == 425 || fe.Status == 429 || fe.Status == 500 ||
                    fe.Status == 502 || fe.Status == 503 || fe.Status == 504;
            return ex is HttpRequestException || ex is TaskCanceledException;
        }

        private static string Enc(string s) => Uri.EscapeDataString(s);

        // --- misc ---
        public Task<JsonElement> Health() => Request(HttpMethod.Get, "/healthz");
        public Task<JsonElement> Status() => Request(HttpMethod.Get, "/v1/status");

        // --- locks & semaphores ---
        public Task<JsonElement> LockAcquire(string key, long? ttlMs = null, bool wait = true, int max = 1) =>
            LockAcquire(key, ttlMs, wait, max, null);
        public Task<JsonElement> LockAcquire(string key, long? ttlMs, bool wait, int max, RequestOptions? options) =>
            LockAcquireWithWait(key, ttlMs, wait, max, options);
        public Task<JsonElement> TryLock(string key, long? ttlMs = null, int max = 1, RequestOptions? options = null) =>
            LockAcquireWithWait(key, ttlMs, false, max, options);
        public Task<JsonElement> TryLock(string key, long? ttlMs, RequestOptions? options) =>
            LockAcquireWithWait(key, ttlMs, false, 1, options);
        public Task<JsonElement> MustLock(string key, long? ttlMs = null, int max = 1, RequestOptions? options = null) =>
            LockAcquireWithWait(key, ttlMs, true, max, options);
        public Task<JsonElement> MustLock(string key, long? ttlMs, RequestOptions? options) =>
            LockAcquireWithWait(key, ttlMs, true, 1, options);
        public Task<JsonElement> Lock(string key, long? ttlMs = null, int max = 1, RequestOptions? options = null) =>
            MustLock(key, ttlMs, max, options);
        public Task<JsonElement> Lock(string key, long? ttlMs, RequestOptions? options) =>
            MustLock(key, ttlMs, 1, options);
        private Task<JsonElement> LockAcquireWithWait(string key, long? ttlMs, bool wait, int max, RequestOptions? options) =>
            Request(HttpMethod.Post, "/v1/locks/acquire", new { key, ttl_ms = ttlMs, wait, max }, options, true);
        public Task<JsonElement> LockRelease(string key, string holder, long fencingToken) =>
            Request(HttpMethod.Post, "/v1/locks/release", new { holder, fencing_token = fencingToken });
        public Task<JsonElement> SemaphoreAcquire(string key, long? ttlMs = null, bool wait = true, int max = 2) =>
            SemaphoreAcquire(key, ttlMs, wait, max, null);
        public Task<JsonElement> SemaphoreAcquire(string key, long? ttlMs, bool wait, int max, RequestOptions? options) =>
            SemaphoreAcquireWithWait(key, ttlMs, wait, max, options);
        public Task<JsonElement> TrySemaphore(string key, long? ttlMs = null, int max = 2, RequestOptions? options = null) =>
            SemaphoreAcquireWithWait(key, ttlMs, false, max, options);
        public Task<JsonElement> MustSemaphore(string key, long? ttlMs = null, int max = 2, RequestOptions? options = null) =>
            SemaphoreAcquireWithWait(key, ttlMs, true, max, options);
        public Task<JsonElement> Semaphore(string key, long? ttlMs = null, int max = 2, RequestOptions? options = null) =>
            MustSemaphore(key, ttlMs, max, options);
        private Task<JsonElement> SemaphoreAcquireWithWait(string key, long? ttlMs, bool wait, int max, RequestOptions? options) =>
            Request(HttpMethod.Post, "/v1/semaphores/acquire", new { key, ttl_ms = ttlMs, wait, limit = Math.Max(max, 2) }, options, true);
        public Task<JsonElement> SemaphoreRelease(string key, string holder, long fencingToken) =>
            Request(HttpMethod.Post, "/v1/semaphores/release", new { key, holder, fencing_token = fencingToken });

        // --- reader-writer locks ---
        public Task<JsonElement> RwAcquireRead(string key, long? ttlMs = null, bool wait = true) =>
            Request(HttpMethod.Post, $"/v1/rw/{Enc(key)}/read", new { ttl_ms = ttlMs, wait });
        public Task<JsonElement> RwEndRead(string key, string lockId) =>
            Request(HttpMethod.Post, $"/v1/rw/{Enc(key)}/read/end", new { lock_id = lockId });
        public Task<JsonElement> RwAcquireWrite(string key, long? ttlMs = null, bool wait = true) =>
            Request(HttpMethod.Post, $"/v1/rw/{Enc(key)}/write", new { ttl_ms = ttlMs, wait });
        public Task<JsonElement> RwEndWrite(string key, string lockId) =>
            Request(HttpMethod.Post, $"/v1/rw/{Enc(key)}/write/end", new { lock_id = lockId });

        // --- config KV ---
        public Task<JsonElement> KvGet(string key) => Request(HttpMethod.Get, $"/v1/kv?key={Enc(key)}");
        public Task<JsonElement> KvPut(string key, string value, long? ttlMs = null) =>
            Request(HttpMethod.Put, $"/v1/kv?key={Enc(key)}", new { value, ttl_ms = ttlMs });
        public Task<JsonElement> KvDelete(string key) => Request(HttpMethod.Delete, $"/v1/kv?key={Enc(key)}");
        public Task<JsonElement> KvList(string prefix) => Request(HttpMethod.Get, $"/v1/kv?prefix={Enc(prefix)}");

        // --- leader election ---
        public Task<JsonElement> ElectionCampaign(string name, string candidate, long ttlMs) =>
            Request(HttpMethod.Post, $"/v1/elections/{Enc(name)}/campaign", new { candidate, ttl_ms = ttlMs });
        public Task<JsonElement> ElectionRenew(string name, string candidate, long fencingToken) =>
            Request(HttpMethod.Post, $"/v1/elections/{Enc(name)}/renew", new { candidate, fencing_token = fencingToken });
        public Task<JsonElement> ElectionResign(string name, string candidate, long fencingToken) =>
            Request(HttpMethod.Post, $"/v1/elections/{Enc(name)}/resign", new { candidate, fencing_token = fencingToken });
        public Task<JsonElement> ElectionGet(string name) => Request(HttpMethod.Get, $"/v1/elections/{Enc(name)}");

        // --- service discovery ---
        public Task<JsonElement> ServiceRegister(string service, string instanceId, string address, long ttlMs) =>
            Request(HttpMethod.Put, $"/v1/services/{Enc(service)}/instances/{Enc(instanceId)}", new { address, ttl_ms = ttlMs });
        public Task<JsonElement> ServiceHeartbeat(string service, string instanceId) =>
            Request(HttpMethod.Post, $"/v1/services/{Enc(service)}/instances/{Enc(instanceId)}/heartbeat");
        public Task<JsonElement> ServiceDeregister(string service, string instanceId) =>
            Request(HttpMethod.Delete, $"/v1/services/{Enc(service)}/instances/{Enc(instanceId)}");
        public Task<JsonElement> ServiceInstances(string service) => Request(HttpMethod.Get, $"/v1/services/{Enc(service)}");
        public Task<JsonElement> ServiceList() => Request(HttpMethod.Get, "/v1/services");
    }
}
