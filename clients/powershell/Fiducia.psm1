# Fiducia HTTP client (PowerShell module). Uses Invoke-RestMethod. Implements PROTOCOL.md.
#
#   Import-Module ./Fiducia.psm1
#   $c = [FiduciaClient]::new("https://api.fiducia.cloud")
#   $lock = $c.LockAcquire("orders/checkout", 30000, $true, 1)
#   $c.LockRelease("orders/checkout", $lock.result.lock_id)

class FiduciaClient {
    [string] $Base

    FiduciaClient([string] $baseUrl) {
        $this.Base = $baseUrl.TrimEnd('/')
    }

    hidden [object] Request([string] $method, [string] $path, [object] $body) {
        $params = @{ Method = $method; Uri = "$($this.Base)$path" }
        if ($null -ne $body) {
            $params.Body = ($body | ConvertTo-Json -Compress)
            $params.ContentType = 'application/json'
        }
        return Invoke-RestMethod @params
    }

    hidden static [string] Enc([string] $s) { return [uri]::EscapeDataString($s) }

    # --- misc ---
    [object] Health() { return $this.Request('GET', '/healthz', $null) }
    [object] Status() { return $this.Request('GET', '/v1/status', $null) }

    # --- locks & semaphores ---
    [object] LockAcquire([string] $key, [object] $ttlMs, [bool] $wait, [int] $max) {
        return $this.Request('POST', "/v1/locks/$([FiduciaClient]::Enc($key))/acquire", @{ ttl_ms = $ttlMs; wait = $wait; max = $max })
    }
    [object] LockRelease([string] $key, [string] $lockId) {
        return $this.Request('POST', "/v1/locks/$([FiduciaClient]::Enc($key))/release", @{ lock_id = $lockId })
    }

    # --- reader-writer locks ---
    [object] RwAcquireRead([string] $key, [object] $ttlMs, [bool] $wait) {
        return $this.Request('POST', "/v1/rw/$([FiduciaClient]::Enc($key))/read", @{ ttl_ms = $ttlMs; wait = $wait })
    }
    [object] RwEndRead([string] $key, [string] $lockId) {
        return $this.Request('POST', "/v1/rw/$([FiduciaClient]::Enc($key))/read/end", @{ lock_id = $lockId })
    }
    [object] RwAcquireWrite([string] $key, [object] $ttlMs, [bool] $wait) {
        return $this.Request('POST', "/v1/rw/$([FiduciaClient]::Enc($key))/write", @{ ttl_ms = $ttlMs; wait = $wait })
    }
    [object] RwEndWrite([string] $key, [string] $lockId) {
        return $this.Request('POST', "/v1/rw/$([FiduciaClient]::Enc($key))/write/end", @{ lock_id = $lockId })
    }

    # --- config KV ---
    [object] KvGet([string] $key) { return $this.Request('GET', "/v1/kv/$([FiduciaClient]::Enc($key))", $null) }
    [object] KvPut([string] $key, [string] $value, [object] $ttlMs) {
        return $this.Request('PUT', "/v1/kv/$([FiduciaClient]::Enc($key))", @{ value = $value; ttl_ms = $ttlMs })
    }
    [object] KvDelete([string] $key) { return $this.Request('DELETE', "/v1/kv/$([FiduciaClient]::Enc($key))", $null) }
    [object] KvList([string] $prefix) { return $this.Request('GET', "/v1/kv?prefix=$([FiduciaClient]::Enc($prefix))", $null) }

    # --- leader election ---
    [object] ElectionCampaign([string] $name, [string] $candidate, [long] $ttlMs) {
        return $this.Request('POST', "/v1/elections/$([FiduciaClient]::Enc($name))/campaign", @{ candidate = $candidate; ttl_ms = $ttlMs })
    }
    [object] ElectionRenew([string] $name, [string] $candidate, [long] $fencingToken) {
        return $this.Request('POST', "/v1/elections/$([FiduciaClient]::Enc($name))/renew", @{ candidate = $candidate; fencing_token = $fencingToken })
    }
    [object] ElectionResign([string] $name, [string] $candidate, [long] $fencingToken) {
        return $this.Request('POST', "/v1/elections/$([FiduciaClient]::Enc($name))/resign", @{ candidate = $candidate; fencing_token = $fencingToken })
    }
    [object] ElectionGet([string] $name) { return $this.Request('GET', "/v1/elections/$([FiduciaClient]::Enc($name))", $null) }

    # --- service discovery ---
    [object] ServiceRegister([string] $service, [string] $instanceId, [string] $address, [long] $ttlMs) {
        return $this.Request('PUT', "/v1/services/$([FiduciaClient]::Enc($service))/instances/$([FiduciaClient]::Enc($instanceId))", @{ address = $address; ttl_ms = $ttlMs })
    }
    [object] ServiceHeartbeat([string] $service, [string] $instanceId) {
        return $this.Request('POST', "/v1/services/$([FiduciaClient]::Enc($service))/instances/$([FiduciaClient]::Enc($instanceId))/heartbeat", $null)
    }
    [object] ServiceDeregister([string] $service, [string] $instanceId) {
        return $this.Request('DELETE', "/v1/services/$([FiduciaClient]::Enc($service))/instances/$([FiduciaClient]::Enc($instanceId))", $null)
    }
    [object] ServiceInstances([string] $service) { return $this.Request('GET', "/v1/services/$([FiduciaClient]::Enc($service))", $null) }
    [object] ServiceList() { return $this.Request('GET', '/v1/services', $null) }
}
