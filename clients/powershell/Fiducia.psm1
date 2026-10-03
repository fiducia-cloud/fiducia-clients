# Fiducia HTTP client (PowerShell module). Uses Invoke-RestMethod. Implements PROTOCOL.md.
#
#   using module ./Fiducia.psm1
#   $c = [FiduciaClient]::new("https://api.fiducia.cloud")
#   $lock = $c.LockAcquire("orders/checkout", 30000, $true, 1)
#   $c.LockRelease("orders/checkout", "worker-a", $lock.result.output.fencing_token)

class FiduciaClient {
    [string] $Base
    [int] $RequestTimeoutSec = 0
    [int] $LockRequestTimeoutSec = 0
    [int] $RetryMax = 0
    [int] $RetryDelayMs = 0

    FiduciaClient([string] $baseUrl) {
        $this.Base = $baseUrl.TrimEnd('/')
    }

    hidden [object] Request([string] $method, [string] $path, [object] $body) {
        return $this.RequestWithOptions($method, $path, $body, $null, $false)
    }

    hidden [object] RequestWithOptions([string] $method, [string] $path, [object] $body, [hashtable] $options, [bool] $lockAcquire) {
        $maxRetries = $this.ResolveRetries($options)
        for ($attempt = 0; ; $attempt++) {
            try {
                return $this.RequestOnce($method, $path, $body, $options, $lockAcquire)
            } catch {
                if (($attempt -ge $maxRetries) -or (-not [FiduciaClient]::Retryable($_.Exception))) {
                    throw
                }
                $delay = $this.ResolveRetryDelayMs($options)
                if ($delay -gt 0) { Start-Sleep -Milliseconds $delay }
            }
        }
        return $null
    }

    hidden [object] RequestOnce([string] $method, [string] $path, [object] $body, [hashtable] $options, [bool] $lockAcquire) {
        $params = @{ Method = $method; Uri = "$($this.Base)$path" }
        $timeout = $this.ResolveTimeoutSec($options, $lockAcquire)
        if ($timeout -gt 0) { $params.TimeoutSec = $timeout }
        if ($null -ne $body) {
            $params.Body = ($body | ConvertTo-Json -Compress)
            $params.ContentType = 'application/json'
        }
        return Invoke-RestMethod @params
    }

    hidden [int] ResolveTimeoutSec([hashtable] $options, [bool] $lockAcquire) {
        foreach ($key in @('LockRequestTimeoutSec', 'RequestTimeoutSec', 'TimeoutSec')) {
            if (($null -ne $options) -and $options.ContainsKey($key) -and ($null -ne $options[$key])) {
                return [int] $options[$key]
            }
        }
        if ($lockAcquire -and $this.LockRequestTimeoutSec -gt 0) { return $this.LockRequestTimeoutSec }
        return $this.RequestTimeoutSec
    }

    hidden [int] ResolveRetries([hashtable] $options) {
        foreach ($key in @('MaxRetries', 'RetryMax', 'Retries')) {
            if (($null -ne $options) -and $options.ContainsKey($key) -and ($null -ne $options[$key])) {
                return [Math]::Max(0, [int] $options[$key])
            }
        }
        return [Math]::Max(0, $this.RetryMax)
    }

    hidden [int] ResolveRetryDelayMs([hashtable] $options) {
        if (($null -ne $options) -and $options.ContainsKey('RetryDelayMs') -and ($null -ne $options.RetryDelayMs)) {
            return [Math]::Max(0, [int] $options.RetryDelayMs)
        }
        return [Math]::Max(0, $this.RetryDelayMs)
    }

    hidden static [bool] Retryable([Exception] $e) {
        if ($null -ne $e.Response -and $null -ne $e.Response.StatusCode) {
            return @(408, 425, 429, 500, 502, 503, 504) -contains [int] $e.Response.StatusCode
        }
        return $true
    }

    hidden static [string] Enc([string] $s) { return [uri]::EscapeDataString($s) }

    # --- misc ---
    [object] Health() { return $this.Request('GET', '/healthz', $null) }
    [object] Status() { return $this.Request('GET', '/v1/status', $null) }

    # --- locks & semaphores ---
    [object] LockAcquire([string] $key, [object] $ttlMs, [bool] $wait, [int] $max) {
        return $this.LockAcquireWithOptions($key, $ttlMs, $wait, $max, $null)
    }
    [object] LockAcquireWithOptions([string] $key, [object] $ttlMs, [bool] $wait, [int] $max, [hashtable] $options) {
        return $this.LockAcquireWithWait($key, $ttlMs, $wait, $max, $options)
    }
    [object] TryLock([string] $key, [object] $ttlMs) {
        return $this.LockAcquireWithWait($key, $ttlMs, $false, 1, $null)
    }
    [object] TryLock([string] $key, [object] $ttlMs, [int] $max) {
        return $this.LockAcquireWithWait($key, $ttlMs, $false, $max, $null)
    }
    [object] TryLock([string] $key, [object] $ttlMs, [hashtable] $options) {
        return $this.LockAcquireWithWait($key, $ttlMs, $false, 1, $options)
    }
    [object] TryLock([string] $key, [object] $ttlMs, [int] $max, [hashtable] $options) {
        return $this.LockAcquireWithWait($key, $ttlMs, $false, $max, $options)
    }
    [object] TryLockWithOptions([string] $key, [object] $ttlMs, [int] $max, [hashtable] $options) {
        return $this.LockAcquireWithWait($key, $ttlMs, $false, $max, $options)
    }
    [object] MustLock([string] $key, [object] $ttlMs) {
        return $this.LockAcquireWithWait($key, $ttlMs, $true, 1, $null)
    }
    [object] MustLock([string] $key, [object] $ttlMs, [int] $max) {
        return $this.LockAcquireWithWait($key, $ttlMs, $true, $max, $null)
    }
    [object] MustLock([string] $key, [object] $ttlMs, [hashtable] $options) {
        return $this.LockAcquireWithWait($key, $ttlMs, $true, 1, $options)
    }
    [object] MustLock([string] $key, [object] $ttlMs, [int] $max, [hashtable] $options) {
        return $this.LockAcquireWithWait($key, $ttlMs, $true, $max, $options)
    }
    [object] MustLockWithOptions([string] $key, [object] $ttlMs, [int] $max, [hashtable] $options) {
        return $this.LockAcquireWithWait($key, $ttlMs, $true, $max, $options)
    }
    [object] Lock([string] $key, [object] $ttlMs) {
        return $this.MustLock($key, $ttlMs)
    }
    [object] Lock([string] $key, [object] $ttlMs, [hashtable] $options) {
        return $this.MustLock($key, $ttlMs, 1, $options)
    }
    [object] Lock([string] $key, [object] $ttlMs, [int] $max) {
        return $this.MustLock($key, $ttlMs, $max)
    }
    [object] Lock([string] $key, [object] $ttlMs, [int] $max, [hashtable] $options) {
        return $this.MustLock($key, $ttlMs, $max, $options)
    }
    [object] LockWithOptions([string] $key, [object] $ttlMs, [int] $max, [hashtable] $options) {
        return $this.MustLockWithOptions($key, $ttlMs, $max, $options)
    }
    hidden [object] LockAcquireWithWait([string] $key, [object] $ttlMs, [bool] $wait, [int] $max, [hashtable] $options) {
        return $this.RequestWithOptions('POST', '/v1/locks/acquire', @{ key = $key; ttl_ms = $ttlMs; wait = $wait; max = $max }, $options, $true)
    }
    [object] LockRelease([string] $key, [string] $holder, [long] $fencingToken) {
        return $this.Request('POST', '/v1/locks/release', @{ holder = $holder; fencing_token = $fencingToken })
    }
    [object] SemaphoreAcquire([string] $key, [object] $ttlMs, [bool] $wait, [int] $max) {
        return $this.SemaphoreAcquireWithOptions($key, $ttlMs, $wait, $max, $null)
    }
    [object] SemaphoreAcquireWithOptions([string] $key, [object] $ttlMs, [bool] $wait, [int] $max, [hashtable] $options) {
        return $this.SemaphoreAcquireWithWait($key, $ttlMs, $wait, $max, $options)
    }
    [object] TrySemaphore([string] $key, [object] $ttlMs, [int] $max) {
        return $this.SemaphoreAcquireWithWait($key, $ttlMs, $false, $max, $null)
    }
    [object] TrySemaphoreWithOptions([string] $key, [object] $ttlMs, [int] $max, [hashtable] $options) {
        return $this.SemaphoreAcquireWithWait($key, $ttlMs, $false, $max, $options)
    }
    [object] MustSemaphore([string] $key, [object] $ttlMs, [int] $max) {
        return $this.SemaphoreAcquireWithWait($key, $ttlMs, $true, $max, $null)
    }
    [object] MustSemaphoreWithOptions([string] $key, [object] $ttlMs, [int] $max, [hashtable] $options) {
        return $this.SemaphoreAcquireWithWait($key, $ttlMs, $true, $max, $options)
    }
    [object] Semaphore([string] $key, [object] $ttlMs, [int] $max) {
        return $this.MustSemaphore($key, $ttlMs, $max)
    }
    [object] SemaphoreWithOptions([string] $key, [object] $ttlMs, [int] $max, [hashtable] $options) {
        return $this.MustSemaphoreWithOptions($key, $ttlMs, $max, $options)
    }
    hidden [object] SemaphoreAcquireWithWait([string] $key, [object] $ttlMs, [bool] $wait, [int] $max, [hashtable] $options) {
        return $this.RequestWithOptions('POST', '/v1/semaphores/acquire', @{ key = $key; ttl_ms = $ttlMs; wait = $wait; limit = [Math]::Max($max, 2) }, $options, $true)
    }
    [object] SemaphoreRelease([string] $key, [string] $holder, [long] $fencingToken) {
        return $this.Request('POST', '/v1/semaphores/release', @{ key = $key; holder = $holder; fencing_token = $fencingToken })
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
    [object] KvGet([string] $key) { return $this.Request('GET', "/v1/kv?key=$([FiduciaClient]::Enc($key))", $null) }
    [object] KvPut([string] $key, [string] $value, [object] $ttlMs) {
        return $this.Request('PUT', "/v1/kv?key=$([FiduciaClient]::Enc($key))", @{ value = $value; ttl_ms = $ttlMs })
    }
    [object] KvDelete([string] $key) { return $this.Request('DELETE', "/v1/kv?key=$([FiduciaClient]::Enc($key))", $null) }
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
