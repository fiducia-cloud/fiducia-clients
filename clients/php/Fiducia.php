<?php
// Fiducia HTTP client (PHP). Zero-dependency — ext-curl + json. Implements PROTOCOL.md.
//
//   require "Fiducia.php";
//   $c = new Fiducia\Client("https://api.fiducia.cloud");
//   $lock = $c->lockAcquire("orders/checkout", 30000);
//   $c->lockRelease("orders/checkout", $lock["result"]["lock_id"]);

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

    public function __construct(string $baseUrl)
    {
        $this->base = rtrim($baseUrl, "/");
    }

    private function request(string $method, string $path, $body = null)
    {
        $ch = curl_init($this->base . $path);
        curl_setopt($ch, CURLOPT_CUSTOMREQUEST, $method);
        curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
        if ($body !== null) {
            curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($body));
            curl_setopt($ch, CURLOPT_HTTPHEADER, ["content-type: application/json"]);
        }
        $resp = curl_exec($ch);
        $code = curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
        curl_close($ch);
        $data = ($resp !== "" && $resp !== false) ? json_decode($resp, true) : null;
        if ($code >= 300) {
            throw new FiduciaException($code, $data);
        }
        return $data;
    }

    private static function enc(string $s): string
    {
        return rawurlencode($s);
    }

    // --- misc ---
    public function health() { return $this->request("GET", "/healthz"); }
    public function status() { return $this->request("GET", "/v1/status"); }

    // --- locks (current protocol: holder + fencing_token, key in the body) ---
    public function lockGet(string $key)
    {
        return $this->request("GET", "/v1/locks?key=" . self::enc($key));
    }
    public function lockAcquire($keys, ?string $holder = null, ?int $ttlMs = null, bool $wait = false)
    {
        return $this->request("POST", "/v1/locks/acquire",
            ["keys" => is_array($keys) ? $keys : [$keys], "holder" => $holder, "ttl_ms" => $ttlMs, "wait" => $wait]);
    }
    public function lockRelease(string $holder, int $fencingToken)
    {
        return $this->request("POST", "/v1/locks/release", ["holder" => $holder, "fencing_token" => $fencingToken]);
    }

    // --- semaphores ---
    public function semaphoreGet(string $key)
    {
        return $this->request("GET", "/v1/semaphores?key=" . self::enc($key));
    }
    public function semaphoreAcquire(string $key, int $limit, ?string $holder = null, ?int $ttlMs = null, bool $wait = false)
    {
        return $this->request("POST", "/v1/semaphores/acquire",
            ["key" => $key, "limit" => $limit, "holder" => $holder, "ttl_ms" => $ttlMs, "wait" => $wait]);
    }
    public function semaphoreRelease(string $key, string $holder, int $fencingToken)
    {
        return $this->request("POST", "/v1/semaphores/release",
            ["key" => $key, "holder" => $holder, "fencing_token" => $fencingToken]);
    }

    // --- high-level blocking / try acquisition (live-mutex style) ---

    /** tryLock: wait:false — returns a Lock if free right now, else null. */
    public function tryLock($key, int $ttlMs = 60000, ?string $holder = null): ?Lock
    {
        return $this->acquireLock(is_array($key) ? $key : [$key], false, $ttlMs, $holder, 0, 0, null);
    }

    /** lock: wait:true — blocks until acquired, the budget elapses (LockTimeout), or error. */
    public function lock($key, int $ttlMs = 60000, ?string $holder = null,
        int $maxWaitMs = 30000, int $retryIntervalMs = 250, ?int $maxRetries = null): Lock
    {
        $keys = is_array($key) ? $key : [$key];
        $got = $this->acquireLock($keys, true, $ttlMs, $holder, $maxWaitMs, $retryIntervalMs, $maxRetries);
        if ($got === null) {
            throw new LockTimeout($keys, $maxWaitMs);
        }
        return $got;
    }

    /** mustLock is an alias of lock. */
    public function mustLock($key, int $ttlMs = 60000, ?string $holder = null,
        int $maxWaitMs = 30000, int $retryIntervalMs = 250, ?int $maxRetries = null): Lock
    {
        return $this->lock($key, $ttlMs, $holder, $maxWaitMs, $retryIntervalMs, $maxRetries);
    }

    /** trySemaphore: wait:false — returns a handle if a permit is free, else null. */
    public function trySemaphore(string $key, int $limit, int $ttlMs = 60000, ?string $holder = null): ?SemaphoreHandle
    {
        return $this->acquireSemaphoreInner($key, $limit, false, $ttlMs, $holder, 0, 0, null);
    }

    /** acquireSemaphore: wait:true — blocks until a permit frees, budget elapses, or error. */
    public function acquireSemaphore(string $key, int $limit, int $ttlMs = 60000, ?string $holder = null,
        int $maxWaitMs = 30000, int $retryIntervalMs = 250, ?int $maxRetries = null): SemaphoreHandle
    {
        $got = $this->acquireSemaphoreInner($key, $limit, true, $ttlMs, $holder, $maxWaitMs, $retryIntervalMs, $maxRetries);
        if ($got === null) {
            throw new LockTimeout([$key], $maxWaitMs);
        }
        return $got;
    }

    private function acquireLock(array $keys, bool $wait, int $ttlMs, ?string $holder,
        int $maxWaitMs, int $retryIntervalMs, ?int $maxRetries): ?Lock
    {
        $holder = $holder ?? self::genHolder();
        $out = self::output($this->lockAcquire($keys, $holder, $ttlMs, $wait));
        if (!empty($out["acquired"])) {
            return new Lock($this, $keys, $holder, (int)($out["fencing_token"] ?? 0), $out["lease_expires_ms"] ?? null);
        }
        if (!$wait) {
            return null; // tryLock: held now -> fail fast
        }
        $deadline = self::nowMs() + $maxWaitMs;
        $attempts = 0;
        while ($maxRetries === null || $attempts < $maxRetries) {
            $attempts++;
            $remaining = $deadline - self::nowMs();
            if ($remaining <= 0) {
                break;
            }
            usleep(min($retryIntervalMs, $remaining) * 1000);
            $lk = $this->lockGet($keys[0])["lock"] ?? null;
            if ($lk && ($lk["holder"] ?? null) === $holder && isset($lk["fencing_token"])) {
                return new Lock($this, $keys, $holder, (int)$lk["fencing_token"], $lk["lease_expires_ms"] ?? null);
            }
        }
        return null;
    }

    private function acquireSemaphoreInner(string $key, int $limit, bool $wait, int $ttlMs, ?string $holder,
        int $maxWaitMs, int $retryIntervalMs, ?int $maxRetries): ?SemaphoreHandle
    {
        $holder = $holder ?? self::genHolder();
        $out = self::output($this->semaphoreAcquire($key, $limit, $holder, $ttlMs, $wait));
        if (!empty($out["acquired"])) {
            return new SemaphoreHandle($this, $key, $holder, (int)($out["fencing_token"] ?? 0), $out["lease_expires_ms"] ?? null);
        }
        if (!$wait) {
            return null;
        }
        $deadline = self::nowMs() + $maxWaitMs;
        $attempts = 0;
        while ($maxRetries === null || $attempts < $maxRetries) {
            $attempts++;
            $remaining = $deadline - self::nowMs();
            if ($remaining <= 0) {
                break;
            }
            usleep(min($retryIntervalMs, $remaining) * 1000);
            $sem = $this->semaphoreGet($key)["semaphore"] ?? null;
            foreach (($sem["holders"] ?? []) as $slot) {
                if (($slot["holder"] ?? null) === $holder && isset($slot["fencing_token"])) {
                    return new SemaphoreHandle($this, $key, $holder, (int)$slot["fencing_token"], $slot["lease_expires_ms"] ?? null);
                }
            }
        }
        return null;
    }

    private static function output($resp): array
    {
        $out = $resp["result"]["output"] ?? null;
        return is_array($out) ? $out : [];
    }

    private static function genHolder(): string
    {
        return "fdc-" . bin2hex(random_bytes(8));
    }

    private static function nowMs(): int
    {
        return (int)(hrtime(true) / 1000000);
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
    public function kvGet(string $key) { return $this->request("GET", "/v1/kv/" . self::enc($key)); }
    public function kvPut(string $key, string $value, ?int $ttlMs = null)
    {
        return $this->request("PUT", "/v1/kv/" . self::enc($key), ["value" => $value, "ttl_ms" => $ttlMs]);
    }
    public function kvDelete(string $key) { return $this->request("DELETE", "/v1/kv/" . self::enc($key)); }
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
