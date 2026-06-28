// Fiducia HTTP client (C# / .NET). Uses HttpClient + System.Text.Json (built-in).
// Implements PROTOCOL.md.
//
//   var c = new Fiducia.FiduciaClient("https://api.fiducia.cloud");
//   var lk = await c.Lock("orders/checkout");   // blocks until acquired
//   await lk.ReleaseAsync();
//   // non-blocking: var l = await c.TryLock("orders/checkout"); if (l != null) await l.ReleaseAsync();

using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Text;
using System.Text.Json;
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

    /// <summary>Thrown by blocking Lock()/AcquireSemaphore() when the wait budget elapses.</summary>
    public class LockTimeoutException : Exception
    {
        public IReadOnlyList<string> Keys { get; }
        public long WaitedMs { get; }
        public LockTimeoutException(IReadOnlyList<string> keys, long waitedMs)
            : base($"fiducia: timed out after {waitedMs}ms waiting for {string.Join(", ", keys)}")
        {
            Keys = keys;
            WaitedMs = waitedMs;
        }
    }

    /// <summary>A held lock grant. Call ReleaseAsync (alias UnlockAsync) when done.</summary>
    public class Lock
    {
        private readonly FiduciaClient _c;
        public IReadOnlyList<string> Keys { get; }
        public string Holder { get; }
        public long FencingToken { get; }
        public long? LeaseExpiresMs { get; }
        public Lock(FiduciaClient c, IReadOnlyList<string> keys, string holder, long token, long? lease)
        { _c = c; Keys = keys; Holder = holder; FencingToken = token; LeaseExpiresMs = lease; }
        public Task<JsonElement> ReleaseAsync() => _c.LockRelease(Holder, FencingToken);
        public Task<JsonElement> UnlockAsync() => ReleaseAsync();
    }

    /// <summary>A held semaphore permit. Call ReleaseAsync when done.</summary>
    public class SemaphoreHandle
    {
        private readonly FiduciaClient _c;
        public string Key { get; }
        public string Holder { get; }
        public long FencingToken { get; }
        public long? LeaseExpiresMs { get; }
        public SemaphoreHandle(FiduciaClient c, string key, string holder, long token, long? lease)
        { _c = c; Key = key; Holder = holder; FencingToken = token; LeaseExpiresMs = lease; }
        public Task<JsonElement> ReleaseAsync() => _c.SemaphoreRelease(Key, Holder, FencingToken);
        public Task<JsonElement> UnlockAsync() => ReleaseAsync();
    }

    public class FiduciaClient
    {
        private readonly string _base;
        private static readonly HttpClient Http = new HttpClient();

        public FiduciaClient(string baseUrl) => _base = baseUrl.TrimEnd('/');

        private async Task<JsonElement> Request(HttpMethod method, string path, object body = null)
        {
            using var req = new HttpRequestMessage(method, _base + path);
            if (body != null)
                req.Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");
            var res = await Http.SendAsync(req);
            var text = await res.Content.ReadAsStringAsync();
            if ((int)res.StatusCode >= 300) throw new FiduciaException((int)res.StatusCode, text);
            return string.IsNullOrEmpty(text) ? default : JsonDocument.Parse(text).RootElement;
        }

        private static string Enc(string s) => Uri.EscapeDataString(s);

        // --- misc ---
        public Task<JsonElement> Health() => Request(HttpMethod.Get, "/healthz");
        public Task<JsonElement> Status() => Request(HttpMethod.Get, "/v1/status");

        // --- locks (current protocol: holder + fencing_token, keys in the body) ---
        public Task<JsonElement> LockGet(string key) => Request(HttpMethod.Get, $"/v1/locks?key={Enc(key)}");
        public Task<JsonElement> LockAcquire(IReadOnlyList<string> keys, string holder = null, long? ttlMs = null, bool wait = false) =>
            Request(HttpMethod.Post, "/v1/locks/acquire", new { keys, holder, ttl_ms = ttlMs, wait });
        public Task<JsonElement> LockRelease(string holder, long fencingToken) =>
            Request(HttpMethod.Post, "/v1/locks/release", new { holder, fencing_token = fencingToken });

        // --- semaphores ---
        public Task<JsonElement> SemaphoreGet(string key) => Request(HttpMethod.Get, $"/v1/semaphores?key={Enc(key)}");
        public Task<JsonElement> SemaphoreAcquire(string key, int limit, string holder = null, long? ttlMs = null, bool wait = false) =>
            Request(HttpMethod.Post, "/v1/semaphores/acquire", new { key, limit, holder, ttl_ms = ttlMs, wait });
        public Task<JsonElement> SemaphoreRelease(string key, string holder, long fencingToken) =>
            Request(HttpMethod.Post, "/v1/semaphores/release", new { key, holder, fencing_token = fencingToken });

        // --- high-level blocking / try acquisition (live-mutex style) ---

        /// <summary>tryLock: wait:false — returns a Lock if free now, else null.</summary>
        public Task<Lock> TryLock(string key, long ttlMs = 60_000) =>
            AcquireLock(new[] { key }, false, ttlMs, null, 0, 0, -1);

        /// <summary>lock / mustLock: wait:true — block until acquired, the budget
        /// elapses (LockTimeoutException), or the server errors.</summary>
        public async Task<Lock> Lock(string key, long ttlMs = 60_000, int maxWaitMs = 30_000, int retryIntervalMs = 250, int maxRetries = -1)
        {
            var l = await AcquireLock(new[] { key }, true, ttlMs, null, maxWaitMs, retryIntervalMs, maxRetries);
            if (l == null) throw new LockTimeoutException(new[] { key }, maxWaitMs);
            return l;
        }
        public Task<Lock> MustLock(string key, long ttlMs = 60_000, int maxWaitMs = 30_000, int retryIntervalMs = 250, int maxRetries = -1) =>
            Lock(key, ttlMs, maxWaitMs, retryIntervalMs, maxRetries);

        /// <summary>trySemaphore / acquireSemaphore — the same pair for counting semaphores.</summary>
        public Task<SemaphoreHandle> TrySemaphore(string key, int limit, long ttlMs = 60_000) =>
            AcquireSemaphoreInner(key, limit, false, ttlMs, 0, 0, -1);
        public async Task<SemaphoreHandle> AcquireSemaphore(string key, int limit, long ttlMs = 60_000, int maxWaitMs = 30_000, int retryIntervalMs = 250, int maxRetries = -1)
        {
            var h = await AcquireSemaphoreInner(key, limit, true, ttlMs, maxWaitMs, retryIntervalMs, maxRetries);
            if (h == null) throw new LockTimeoutException(new[] { key }, maxWaitMs);
            return h;
        }

        private async Task<Lock> AcquireLock(IReadOnlyList<string> keys, bool wait, long ttlMs, string holder, int maxWaitMs, int retryIntervalMs, int maxRetries)
        {
            holder ??= GenHolder();
            var outp = Output(await LockAcquire(keys, holder, ttlMs, wait));
            if (GetBool(outp, "acquired"))
                return new Lock(this, keys, holder, GetLong(outp, "fencing_token"), GetLongOrNull(outp, "lease_expires_ms"));
            if (!wait) return null; // tryLock: held now -> fail fast

            var deadline = NowMs() + maxWaitMs;
            for (int attempt = 0; maxRetries < 0 || attempt < maxRetries; attempt++)
            {
                var remaining = deadline - NowMs();
                if (remaining <= 0) break;
                await Task.Delay((int)Math.Min(retryIntervalMs, remaining));
                var resp = await LockGet(keys[0]);
                if (resp.ValueKind == JsonValueKind.Object && resp.TryGetProperty("lock", out var lk) && lk.ValueKind == JsonValueKind.Object)
                {
                    if (GetStr(lk, "holder") == holder && lk.TryGetProperty("fencing_token", out var ft) && ft.ValueKind == JsonValueKind.Number)
                        return new Lock(this, keys, holder, ft.GetInt64(), GetLongOrNull(lk, "lease_expires_ms"));
                }
            }
            return null;
        }

        private async Task<SemaphoreHandle> AcquireSemaphoreInner(string key, int limit, bool wait, long ttlMs, int maxWaitMs, int retryIntervalMs, int maxRetries)
        {
            var holder = GenHolder();
            var outp = Output(await SemaphoreAcquire(key, limit, holder, ttlMs, wait));
            if (GetBool(outp, "acquired"))
                return new SemaphoreHandle(this, key, holder, GetLong(outp, "fencing_token"), GetLongOrNull(outp, "lease_expires_ms"));
            if (!wait) return null;

            var deadline = NowMs() + maxWaitMs;
            for (int attempt = 0; maxRetries < 0 || attempt < maxRetries; attempt++)
            {
                var remaining = deadline - NowMs();
                if (remaining <= 0) break;
                await Task.Delay((int)Math.Min(retryIntervalMs, remaining));
                var resp = await SemaphoreGet(key);
                if (resp.ValueKind == JsonValueKind.Object && resp.TryGetProperty("semaphore", out var sem)
                    && sem.TryGetProperty("holders", out var holders) && holders.ValueKind == JsonValueKind.Array)
                {
                    foreach (var slot in holders.EnumerateArray())
                    {
                        if (GetStr(slot, "holder") == holder && slot.TryGetProperty("fencing_token", out var ft) && ft.ValueKind == JsonValueKind.Number)
                            return new SemaphoreHandle(this, key, holder, ft.GetInt64(), GetLongOrNull(slot, "lease_expires_ms"));
                    }
                }
            }
            return null;
        }

        private static string GenHolder() => "fdc-" + Guid.NewGuid().ToString("N");
        private static long NowMs() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        private static JsonElement Output(JsonElement resp) =>
            resp.ValueKind == JsonValueKind.Object && resp.TryGetProperty("result", out var r)
                && r.TryGetProperty("output", out var o) ? o : default;
        private static bool GetBool(JsonElement e, string name) =>
            e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.True;
        private static string GetStr(JsonElement e, string name) =>
            e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
        private static long GetLong(JsonElement e, string name) =>
            e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt64() : 0L;
        private static long? GetLongOrNull(JsonElement e, string name) =>
            e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt64() : (long?)null;

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
        public Task<JsonElement> KvGet(string key) => Request(HttpMethod.Get, $"/v1/kv/{Enc(key)}");
        public Task<JsonElement> KvPut(string key, string value, long? ttlMs = null) =>
            Request(HttpMethod.Put, $"/v1/kv/{Enc(key)}", new { value, ttl_ms = ttlMs });
        public Task<JsonElement> KvDelete(string key) => Request(HttpMethod.Delete, $"/v1/kv/{Enc(key)}");
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
