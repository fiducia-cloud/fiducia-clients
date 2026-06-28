# Fiducia HTTP client (PowerShell module). Uses Invoke-RestMethod. Implements PROTOCOL.md.
#
#   Import-Module ./Fiducia.psm1
#   $c = [FiduciaClient]::new("https://api.fiducia.cloud")
#   $lock = $c.LockAcquire("orders/checkout", 30000, $true, 1)
#   $c.LockRelease("orders/checkout", $lock.result.lock_id)

# A held lock grant. Call Release() (alias Unlock()) when done. `Client` is kept
# untyped to avoid a forward-reference cycle with FiduciaClient at parse time.
class FiduciaLock {
    [object] $Client
    [string[]] $Keys
    [string] $Holder
    [long] $FencingToken
    [object] $LeaseExpiresMs
    [object] Release() { return $this.Client.LockRelease($this.Holder, $this.FencingToken) }
    [object] Unlock() { return $this.Release() }
}

# A held semaphore permit. Call Release() when done.
class FiduciaSemaphore {
    [object] $Client
    [string] $Key
    [string] $Holder
    [long] $FencingToken
    [object] $LeaseExpiresMs
    [object] Release() { return $this.Client.SemaphoreRelease($this.Key, $this.Holder, $this.FencingToken) }
    [object] Unlock() { return $this.Release() }
}

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

    # --- locks (current protocol: holder + fencing_token, key in the body) ---
    [object] LockGet([string] $key) {
        return $this.Request('GET', "/v1/locks?key=$([FiduciaClient]::Enc($key))", $null)
    }
    [object] LockAcquire([string[]] $keys, [string] $holder, [object] $ttlMs, [bool] $wait) {
        return $this.Request('POST', '/v1/locks/acquire', @{ keys = $keys; holder = $holder; ttl_ms = $ttlMs; wait = $wait })
    }
    [object] LockRelease([string] $holder, [long] $fencingToken) {
        return $this.Request('POST', '/v1/locks/release', @{ holder = $holder; fencing_token = $fencingToken })
    }

    # --- semaphores ---
    [object] SemaphoreGet([string] $key) {
        return $this.Request('GET', "/v1/semaphores?key=$([FiduciaClient]::Enc($key))", $null)
    }
    [object] SemaphoreAcquire([string] $key, [int] $limit, [string] $holder, [object] $ttlMs, [bool] $wait) {
        return $this.Request('POST', '/v1/semaphores/acquire', @{ key = $key; limit = $limit; holder = $holder; ttl_ms = $ttlMs; wait = $wait })
    }
    [object] SemaphoreRelease([string] $key, [string] $holder, [long] $fencingToken) {
        return $this.Request('POST', '/v1/semaphores/release', @{ key = $key; holder = $holder; fencing_token = $fencingToken })
    }

    # --- high-level blocking / try acquisition (live-mutex style) ---

    # TryLock: wait:false — returns a FiduciaLock if free now, else $null.
    [object] TryLock([string] $key, [long] $ttlMs) {
        return $this.AcquireLock(@($key), $false, $ttlMs, 0, 0)
    }

    # Lock: wait:true — blocks (polling) until acquired or the budget elapses (throws).
    [object] Lock([string] $key, [long] $ttlMs, [int] $maxWaitMs, [int] $retryIntervalMs) {
        $got = $this.AcquireLock(@($key), $true, $ttlMs, $maxWaitMs, $retryIntervalMs)
        if ($null -eq $got) { throw "fiducia: timed out after ${maxWaitMs}ms waiting for $key" }
        return $got
    }

    # MustLock is an alias of Lock.
    [object] MustLock([string] $key, [long] $ttlMs, [int] $maxWaitMs, [int] $retryIntervalMs) {
        return $this.Lock($key, $ttlMs, $maxWaitMs, $retryIntervalMs)
    }

    # TrySemaphore: wait:false — returns a FiduciaSemaphore if a permit is free, else $null.
    [object] TrySemaphore([string] $key, [int] $limit, [long] $ttlMs) {
        return $this.AcquireSemaphoreInner($key, $limit, $false, $ttlMs, 0, 0)
    }

    # AcquireSemaphore: wait:true — blocks until a permit frees or the budget elapses (throws).
    [object] AcquireSemaphore([string] $key, [int] $limit, [long] $ttlMs, [int] $maxWaitMs, [int] $retryIntervalMs) {
        $got = $this.AcquireSemaphoreInner($key, $limit, $true, $ttlMs, $maxWaitMs, $retryIntervalMs)
        if ($null -eq $got) { throw "fiducia: timed out after ${maxWaitMs}ms waiting for $key" }
        return $got
    }

    hidden [object] AcquireLock([string[]] $keys, [bool] $wait, [long] $ttlMs, [int] $maxWaitMs, [int] $retryIntervalMs) {
        $holder = [FiduciaClient]::GenHolder()
        $out = $this.LockAcquire($keys, $holder, $ttlMs, $wait).result.output
        if ($out.acquired) {
            return [FiduciaLock]@{ Client = $this; Keys = $keys; Holder = $holder; FencingToken = [long]$out.fencing_token; LeaseExpiresMs = $out.lease_expires_ms }
        }
        if (-not $wait) { return $null }  # TryLock: held now -> fail fast
        $deadline = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + $maxWaitMs
        while ($true) {
            $remaining = $deadline - [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            if ($remaining -le 0) { break }
            Start-Sleep -Milliseconds ([Math]::Min($retryIntervalMs, $remaining))
            $lk = $this.LockGet($keys[0]).lock
            if ($lk -and $lk.holder -eq $holder -and $null -ne $lk.fencing_token) {
                return [FiduciaLock]@{ Client = $this; Keys = $keys; Holder = $holder; FencingToken = [long]$lk.fencing_token; LeaseExpiresMs = $lk.lease_expires_ms }
            }
        }
        return $null
    }

    hidden [object] AcquireSemaphoreInner([string] $key, [int] $limit, [bool] $wait, [long] $ttlMs, [int] $maxWaitMs, [int] $retryIntervalMs) {
        $holder = [FiduciaClient]::GenHolder()
        $out = $this.SemaphoreAcquire($key, $limit, $holder, $ttlMs, $wait).result.output
        if ($out.acquired) {
            return [FiduciaSemaphore]@{ Client = $this; Key = $key; Holder = $holder; FencingToken = [long]$out.fencing_token; LeaseExpiresMs = $out.lease_expires_ms }
        }
        if (-not $wait) { return $null }
        $deadline = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + $maxWaitMs
        while ($true) {
            $remaining = $deadline - [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            if ($remaining -le 0) { break }
            Start-Sleep -Milliseconds ([Math]::Min($retryIntervalMs, $remaining))
            $slot = $this.SemaphoreGet($key).semaphore.holders | Where-Object { $_.holder -eq $holder } | Select-Object -First 1
            if ($slot -and $null -ne $slot.fencing_token) {
                return [FiduciaSemaphore]@{ Client = $this; Key = $key; Holder = $holder; FencingToken = [long]$slot.fencing_token; LeaseExpiresMs = $slot.lease_expires_ms }
            }
        }
        return $null
    }

    hidden static [string] GenHolder() { return "fdc-$([guid]::NewGuid().ToString('N'))" }

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
