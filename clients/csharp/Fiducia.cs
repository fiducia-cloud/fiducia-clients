// Fiducia HTTP client (C# / .NET). Uses HttpClient + System.Text.Json (built-in).
// Implements PROTOCOL.md.
//
//   var c = new Fiducia.FiduciaClient("https://api.fiducia.cloud");
//   var lock = await c.LockAcquire("orders/checkout", 30000);
//   await c.LockRelease("orders/checkout", lock.GetProperty("result").GetProperty("lock_id").GetString());

using System;
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

        // --- locks & semaphores ---
        public Task<JsonElement> LockAcquire(string key, long? ttlMs = null, bool wait = true, int max = 1) =>
            Request(HttpMethod.Post, $"/v1/locks/{Enc(key)}/acquire", new { ttl_ms = ttlMs, wait, max });
        public Task<JsonElement> LockRelease(string key, string lockId) =>
            Request(HttpMethod.Post, $"/v1/locks/{Enc(key)}/release", new { lock_id = lockId });

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
