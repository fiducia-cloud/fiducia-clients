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

    // --- locks & semaphores ---
    public function lockAcquire(string $key, ?int $ttlMs = null, bool $wait = true, int $max = 1)
    {
        return $this->request("POST", "/v1/locks/" . self::enc($key) . "/acquire",
            ["ttl_ms" => $ttlMs, "wait" => $wait, "max" => $max]);
    }
    public function lockRelease(string $key, string $lockId)
    {
        return $this->request("POST", "/v1/locks/" . self::enc($key) . "/release", ["lock_id" => $lockId]);
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
