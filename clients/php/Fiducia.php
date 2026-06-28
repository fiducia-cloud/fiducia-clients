<?php
// Fiducia HTTP client (PHP). Zero-dependency — ext-curl + json. Implements PROTOCOL.md.
//
//   require "Fiducia.php";
//   $c = new Fiducia\Client("https://api.fiducia.cloud");
//   $lock = $c->lockAcquire("orders/checkout", 30000);
//   $c->lockRelease("orders/checkout", "worker-a", $lock["result"]["output"]["fencing_token"]);

namespace Fiducia;

class FiduciaException extends \Exception
{
    public int $status;
    public $body;
    public function __construct(int $status, $body)
    {
        parent::__construct("fiducia: HTTP $status");
        $this->status = $status;
        $this->body = $body;
    }
}

/** Thrown by the blocking lock()/acquireSemaphore() when the wait budget elapses. */
class LockTimeout extends \Exception
{
    public array $keys;
    public int $waitedMs;
    public function __construct(array $keys, int $waitedMs)
    {
        parent::__construct("fiducia: timed out after {$waitedMs}ms waiting for " . implode(", ", $keys));
        $this->keys = $keys;
        $this->waitedMs = $waitedMs;
    }
}

/** A held lock grant. Call release() (alias unlock()) when done. */
class Lock
{
    public function __construct(
        private Client $client,
        public array $keys,
        public string $holder,
        public int $fencingToken,
        public $leaseExpiresMs = null
    ) {
    }
    public function release()
    {
        return $this->client->lockRelease($this->holder, $this->fencingToken);
    }
    public function unlock()
    {
        return $this->release();
    }
}

/** A held semaphore permit. Call release() when done. */
class SemaphoreHandle
{
    public function __construct(
        private Client $client,
        public string $key,
        public string $holder,
        public int $fencingToken,
        public $leaseExpiresMs = null
    ) {
    }
    public function release()
    {
        return $this->client->semaphoreRelease($this->key, $this->holder, $this->fencingToken);
    }
    public function unlock()
    {
        return $this->release();
    }
}

class Client
{
    private string $base;
    public ?int $requestTimeoutMs = null;
    public ?int $lockRequestTimeoutMs = null;
    public int $retryMax = 0;
    public int $retryDelayMs = 0;

    public function __construct(string $baseUrl)
    {
        $this->base = rtrim($baseUrl, "/");
    }

    private function request(string $method, string $path, $body = null, array $opts = [], bool $lockAcquire = false)
    {
        $maxRetries = $this->resolveRetries($opts);
        for ($attempt = 0; ; $attempt++) {
            try {
                return $this->requestOnce($method, $path, $body, $opts, $lockAcquire);
            } catch (\Throwable $e) {
                if ($attempt >= $maxRetries || !$this->retryable($e)) {
                    throw $e;
                }
                $delay = $this->resolveRetryDelayMs($opts);
                if ($delay > 0) {
                    usleep($delay * 1000);
                }
            }
        }
    }

    private function requestOnce(string $method, string $path, $body = null, array $opts = [], bool $lockAcquire = false)
    {
        $ch = curl_init($this->base . $path);
        curl_setopt($ch, CURLOPT_CUSTOMREQUEST, $method);
        curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
        $timeoutMs = $this->resolveTimeoutMs($opts, $lockAcquire);
        if ($timeoutMs !== null) {
            curl_setopt($ch, CURLOPT_TIMEOUT_MS, $timeoutMs);
        }
        if ($body !== null) {
            curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($body));
            curl_setopt($ch, CURLOPT_HTTPHEADER, ["content-type: application/json"]);
        }
        $resp = curl_exec($ch);
        $code = curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
        $err = curl_error($ch);
        curl_close($ch);
        if ($resp === false) {
            throw new \RuntimeException($err ?: "fiducia: curl request failed");
        }
        $data = ($resp !== "" && $resp !== false) ? json_decode($resp, true) : null;
        if ($code >= 300) {
            throw new FiduciaException($code, $data);
        }
        return $data;
    }

    private function resolveTimeoutMs(array $opts, bool $lockAcquire): ?int
    {
        foreach (["lock_request_timeout_ms", "request_timeout_ms", "timeout_ms"] as $key) {
            if (array_key_exists($key, $opts) && $opts[$key] !== null) {
                return (int)$opts[$key];
            }
        }
        if ($lockAcquire && $this->lockRequestTimeoutMs !== null) {
            return $this->lockRequestTimeoutMs;
        }
        return $this->requestTimeoutMs;
    }

    private function resolveRetries(array $opts): int
    {
        foreach (["max_retries", "retry_max", "retries"] as $key) {
            if (array_key_exists($key, $opts) && $opts[$key] !== null) {
                return max(0, (int)$opts[$key]);
            }
        }
        return max(0, $this->retryMax);
    }

    private function resolveRetryDelayMs(array $opts): int
    {
        if (array_key_exists("retry_delay_ms", $opts) && $opts["retry_delay_ms"] !== null) {
            return max(0, (int)$opts["retry_delay_ms"]);
        }
        return max(0, $this->retryDelayMs);
    }

    private function retryable(\Throwable $e): bool
    {
        if ($e instanceof FiduciaException) {
            return in_array($e->status, [408, 425, 429, 500, 502, 503, 504], true);
        }
        return true;
    }

    private static function enc(string $s): string
    {
        return rawurlencode($s);
    }

    // --- misc ---
    public function health() { return $this->request("GET", "/healthz"); }
    public function status() { return $this->request("GET", "/v1/status"); }

    // --- locks & semaphores ---
    public function lockAcquire(string $key, ?int $ttlMs = null, bool $wait = true, int $max = 1, array $opts = [])
    {
        return $this->lockAcquireWithWait($key, $ttlMs, $wait, $max, $opts);
    }
    public function tryLock(string $key, ?int $ttlMs = null, int $max = 1, array $opts = [])
    {
        return $this->lockAcquireWithWait($key, $ttlMs, false, $max, $opts);
    }
    public function mustLock(string $key, ?int $ttlMs = null, int $max = 1, array $opts = [])
    {
        return $this->lockAcquireWithWait($key, $ttlMs, true, $max, $opts);
    }
    public function lock(string $key, ?int $ttlMs = null, int $max = 1, array $opts = [])
    {
        return $this->mustLock($key, $ttlMs, $max, $opts);
    }
    private function lockAcquireWithWait(string $key, ?int $ttlMs, bool $wait, int $max, array $opts)
    {
        return $this->request("POST", "/v1/locks/acquire",
            ["key" => $key, "ttl_ms" => $ttlMs, "wait" => $wait, "max" => $max], $opts, true);
    }
    public function lockRelease(string $key, string $holder, int $fencingToken)
    {
        return $this->request("POST", "/v1/locks/release", ["holder" => $holder, "fencing_token" => $fencingToken]);
    }
    public function semaphoreAcquire(string $key, ?int $ttlMs = null, bool $wait = true, int $max = 2, array $opts = [])
    {
        return $this->semaphoreAcquireWithWait($key, $ttlMs, $wait, $max, $opts);
    }
    public function trySemaphore(string $key, ?int $ttlMs = null, int $max = 2, array $opts = [])
    {
        return $this->semaphoreAcquireWithWait($key, $ttlMs, false, $max, $opts);
    }
    public function mustSemaphore(string $key, ?int $ttlMs = null, int $max = 2, array $opts = [])
    {
        return $this->semaphoreAcquireWithWait($key, $ttlMs, true, $max, $opts);
    }
    public function semaphore(string $key, ?int $ttlMs = null, int $max = 2, array $opts = [])
    {
        return $this->mustSemaphore($key, $ttlMs, $max, $opts);
    }
    private function semaphoreAcquireWithWait(string $key, ?int $ttlMs, bool $wait, int $max, array $opts)
    {
        return $this->request("POST", "/v1/semaphores/acquire",
            ["key" => $key, "ttl_ms" => $ttlMs, "wait" => $wait, "limit" => max($max, 2)], $opts, true);
    }
    public function semaphoreRelease(string $key, string $holder, int $fencingToken)
    {
        return $this->request("POST", "/v1/semaphores/release", ["key" => $key, "holder" => $holder, "fencing_token" => $fencingToken]);
    }

    // --- reader-writer locks ---
    public function rwAcquireRead(string $key, ?int $ttlMs = null, bool $wait = true)
    {
        return $this->request("POST", "/v1/rw/" . self::enc($key) . "/read", ["ttl_ms" => $ttlMs, "wait" => $wait]);
    }
    public function rwEndRead(string $key, string $lockId)
    {
        return $this->request("POST", "/v1/rw/" . self::enc($key) . "/read/end", ["lock_id" => $lockId]);
    }
    public function rwAcquireWrite(string $key, ?int $ttlMs = null, bool $wait = true)
    {
        return $this->request("POST", "/v1/rw/" . self::enc($key) . "/write", ["ttl_ms" => $ttlMs, "wait" => $wait]);
    }
    public function rwEndWrite(string $key, string $lockId)
    {
        return $this->request("POST", "/v1/rw/" . self::enc($key) . "/write/end", ["lock_id" => $lockId]);
    }

    // --- config KV ---
    public function kvGet(string $key) { return $this->request("GET", "/v1/kv?key=" . self::enc($key)); }
    public function kvPut(string $key, string $value, ?int $ttlMs = null)
    {
        return $this->request("PUT", "/v1/kv?key=" . self::enc($key), ["value" => $value, "ttl_ms" => $ttlMs]);
    }
    public function kvDelete(string $key) { return $this->request("DELETE", "/v1/kv?key=" . self::enc($key)); }
    public function kvList(string $prefix) { return $this->request("GET", "/v1/kv?prefix=" . self::enc($prefix)); }

    // --- leader election ---
    public function electionCampaign(string $name, string $candidate, int $ttlMs)
    {
        return $this->request("POST", "/v1/elections/" . self::enc($name) . "/campaign",
            ["candidate" => $candidate, "ttl_ms" => $ttlMs]);
    }
    public function electionRenew(string $name, string $candidate, int $fencingToken)
    {
        return $this->request("POST", "/v1/elections/" . self::enc($name) . "/renew",
            ["candidate" => $candidate, "fencing_token" => $fencingToken]);
    }
    public function electionResign(string $name, string $candidate, int $fencingToken)
    {
        return $this->request("POST", "/v1/elections/" . self::enc($name) . "/resign",
            ["candidate" => $candidate, "fencing_token" => $fencingToken]);
    }
    public function electionGet(string $name) { return $this->request("GET", "/v1/elections/" . self::enc($name)); }

    // --- service discovery ---
    public function serviceRegister(string $service, string $instanceId, string $address, int $ttlMs)
    {
        return $this->request("PUT", "/v1/services/" . self::enc($service) . "/instances/" . self::enc($instanceId),
            ["address" => $address, "ttl_ms" => $ttlMs]);
    }
    public function serviceHeartbeat(string $service, string $instanceId)
    {
        return $this->request("POST", "/v1/services/" . self::enc($service) . "/instances/" . self::enc($instanceId) . "/heartbeat");
    }
    public function serviceDeregister(string $service, string $instanceId)
    {
        return $this->request("DELETE", "/v1/services/" . self::enc($service) . "/instances/" . self::enc($instanceId));
    }
    public function serviceInstances(string $service) { return $this->request("GET", "/v1/services/" . self::enc($service)); }
    public function serviceList() { return $this->request("GET", "/v1/services"); }
}
