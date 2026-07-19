"""High-level locking for the Fiducia Python client.

Hand-written (NOT generated): adds the live-mutex-style ergonomics on top of the
generated thin ``FiduciaClient`` in ``fiducia.py``. Two shapes:

    * ``try_lock(key)``  — wait=False. Returns a ``Lock`` if free right now, else
      ``None`` (never blocks).
    * ``lock(key)`` / ``must_lock(key)`` — wait=True. Blocks (polling with a fixed
      interval) until acquired, the budget elapses (``LockTimeout``), or the
      server errors.

Counting semaphores get the same pair (``try_semaphore`` / ``acquire_semaphore``).

The server never holds a request open: ``wait=True`` reserves a FIFO queue slot
and returns immediately, so the *client* owns the wait — hence ``max_wait_ms``,
``retry_interval_ms`` and ``max_retries`` live here.

    from fiducia import FiduciaClient
    from locking import FiduciaLockClient

    c = FiduciaLockClient("https://api.fiducia.cloud")
    lock = c.lock("orders/checkout", ttl_ms=30000)
    try:
        ...  # critical section
    finally:
        lock.release()
"""
import time as _time
import uuid as _uuid

from fiducia import FiduciaClient


class LockTimeout(Exception):
    def __init__(self, keys, waited_ms):
        super().__init__("fiducia: timed out after %dms waiting for %s" % (waited_ms, keys))
        self.keys, self.waited_ms = keys, waited_ms


class Lock:
    """A held lock grant. Call ``release()`` (alias ``unlock()``) when done."""

    def __init__(self, client, keys, holder, fencing_token, lease_expires_ms=None, ttl_ms=60000):
        self._client = client
        self.keys = keys
        self.holder = holder
        self.fencing_token = fencing_token
        self.lease_expires_ms = lease_expires_ms
        self._ttl_ms = ttl_ms

    def renew(self, ttl_ms=None):
        response = self._client.lock_renew(
            self.keys, self.holder, self.fencing_token, ttl_ms or self._ttl_ms
        )
        output = _output(response)
        if not output.get("renewed"):
            raise RuntimeError("fiducia: lock renewal lost fenced authority")
        self.lease_expires_ms = output.get("lease_expires_ms")
        self._ttl_ms = ttl_ms or self._ttl_ms
        return response

    def release(self):
        return self._client.lock_release(self.holder, self.fencing_token)

    unlock = release

    # Context-manager sugar: `with c.lock("k") as lock: ...`
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        try:
            self.release()
        except Exception:
            pass  # best-effort; the lease TTL is the backstop
        return False


class SemaphoreHandle:
    def __init__(self, client, key, holder, fencing_token, lease_expires_ms=None, ttl_ms=60000):
        self._client = client
        self.key = key
        self.holder = holder
        self.fencing_token = fencing_token
        self.lease_expires_ms = lease_expires_ms
        self._ttl_ms = ttl_ms

    def renew(self, ttl_ms=None):
        response = self._client.semaphore_renew(
            self.key, self.holder, self.fencing_token, ttl_ms or self._ttl_ms
        )
        output = _output(response)
        if not output.get("renewed"):
            raise RuntimeError("fiducia: semaphore renewal lost fenced authority")
        self.lease_expires_ms = output.get("lease_expires_ms")
        self._ttl_ms = ttl_ms or self._ttl_ms
        return response

    def release(self):
        return self._client.semaphore_release(self.key, self.holder, self.fencing_token)

    unlock = release

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        try:
            self.release()
        except Exception:
            pass
        return False


def _gen_holder():
    return "fdc-%s" % _uuid.uuid4().hex


def _gen_request_id():
    return "fdc-attempt-%s" % _uuid.uuid4().hex


def _output(resp):
    return ((resp or {}).get("result") or {}).get("output") or {}


def _fencing_token(output, primitive):
    token = output.get("fencing_token")
    if not isinstance(token, int) or isinstance(token, bool) or token <= 0:
        raise RuntimeError("fiducia: acquired %s carried no valid fencing token" % primitive)
    return token


class FiduciaLockClient(FiduciaClient):
    # --- locks ---------------------------------------------------------------

    def try_lock(self, key_or_keys, ttl_ms=60000, holder=None):
        """Take the lock now (wait=False). Returns a Lock or None if held."""
        return self._acquire_lock(_as_list(key_or_keys), False, ttl_ms, holder)

    def lock(self, key_or_keys, ttl_ms=60000, holder=None,
             max_wait_ms=30000, retry_interval_ms=250, max_retries=None):
        """Block until acquired, the budget elapses (LockTimeout), or error."""
        got = self._acquire_lock(_as_list(key_or_keys), True, ttl_ms, holder,
                                 max_wait_ms, retry_interval_ms, max_retries)
        if got is None:
            raise LockTimeout(_as_list(key_or_keys), max_wait_ms)
        return got

    # `must_lock` is an alias of `lock`.
    must_lock = lock

    def with_lock(self, key_or_keys, fn, **opts):
        """Acquire, run ``fn(lock)``, then always release."""
        lock = self.lock(key_or_keys, **opts)
        try:
            return fn(lock)
        finally:
            try:
                lock.release()
            except Exception:
                pass

    def _acquire_lock(self, keys, wait, ttl_ms, holder,
                      max_wait_ms=30000, retry_interval_ms=250, max_retries=None):
        holder = (holder or "").strip() or _gen_holder()
        request_id = _gen_request_id()
        try:
            first = self.lock_acquire_many(
                keys,
                holder=holder,
                request_id=request_id,
                ttl_ms=ttl_ms,
                wait=wait,
                wait_timeout_ms=max_wait_ms if wait else None,
            )
        except Exception:
            self._cancel_lock_wait(keys, holder, request_id)
            raise
        out = _output(first)
        if out.get("acquired"):
            token = _fencing_token(out, "lock")
            if out.get("renewed") is False:
                try:
                    renewed = _output(self.lock_renew(keys, holder, token, ttl_ms))
                    if not renewed.get("renewed"):
                        raise RuntimeError(
                            "fiducia: reacquired lock lost fenced authority during renewal"
                        )
                    return Lock(
                        self, keys, holder, token, renewed.get("lease_expires_ms"), ttl_ms
                    )
                except Exception:
                    self._cancel_lock_wait(keys, holder, request_id)
                    raise
            return Lock(
                self, keys, holder, token, out.get("lease_expires_ms"), ttl_ms
            )
        if not wait:
            return None  # try_lock: held now → fail fast

        deadline = _time.monotonic() + max_wait_ms / 1000.0
        attempts = 0
        acquired = False
        try:
            while max_retries is None or attempts < max_retries:
                remaining = deadline - _time.monotonic()
                if remaining <= 0:
                    break
                delay_ms = min(retry_interval_ms * (2 ** min(attempts, 3)), 2000)
                _time.sleep(min(delay_ms / 1000.0, remaining))
                attempts += 1
                retried = self.lock_acquire_many(
                    keys,
                    holder=holder,
                    request_id=request_id,
                    ttl_ms=ttl_ms,
                    wait=True,
                    wait_timeout_ms=max_wait_ms,
                )
                out = _output(retried)
                if out.get("acquired"):
                    token = _fencing_token(out, "lock")
                    renewed = _output(self.lock_renew(keys, holder, token, ttl_ms))
                    if not renewed.get("renewed"):
                        raise RuntimeError(
                            "fiducia: retry-discovered lock lost fenced authority during renewal"
                        )
                    acquired = True
                    return Lock(
                        self,
                        keys,
                        holder,
                        token,
                        renewed.get("lease_expires_ms"),
                        ttl_ms,
                    )
            return None
        finally:
            if not acquired:
                self._cancel_lock_wait(keys, holder, request_id)

    def _cancel_lock_wait(self, keys, holder, request_id):
        out = _output(self.lock_cancel(keys, holder, request_id=request_id))
        if out.get("acquired"):
            token = _fencing_token(out, "raced lock")
            released = _output(self.lock_release(holder, token))
            if released.get("released") is False:
                raise RuntimeError("fiducia: raced lock could not be released safely")
            return
        if out.get("cancelled") is True:
            return
        raise RuntimeError(
            "fiducia: lock cancellation did not establish safety (%s)"
            % out.get("reason", "invalid_response")
        )

    # --- counting semaphores -------------------------------------------------

    def try_semaphore(self, key, limit, ttl_ms=60000, holder=None):
        """Take a permit now (wait=False). Returns a handle or None if full."""
        return self._acquire_semaphore(key, limit, False, ttl_ms, holder)

    def acquire_semaphore(self, key, limit, ttl_ms=60000, holder=None,
                          max_wait_ms=30000, retry_interval_ms=250, max_retries=None):
        """Block until a permit is free, the budget elapses, or error."""
        got = self._acquire_semaphore(key, limit, True, ttl_ms, holder,
                                      max_wait_ms, retry_interval_ms, max_retries)
        if got is None:
            raise LockTimeout([key], max_wait_ms)
        return got

    def _acquire_semaphore(self, key, limit, wait, ttl_ms, holder,
                           max_wait_ms=30000, retry_interval_ms=250, max_retries=None):
        holder = (holder or "").strip() or _gen_holder()
        request_id = _gen_request_id()
        try:
            first = self.semaphore_acquire(
                key,
                limit,
                holder=holder,
                request_id=request_id,
                ttl_ms=ttl_ms,
                wait=wait,
                wait_timeout_ms=max_wait_ms if wait else None,
            )
        except Exception:
            self._cancel_semaphore_wait(key, holder, request_id)
            raise
        out = _output(first)
        if out.get("acquired"):
            token = _fencing_token(out, "semaphore permit")
            if out.get("renewed") is False:
                try:
                    renewed = _output(self.semaphore_renew(key, holder, token, ttl_ms))
                    if not renewed.get("renewed"):
                        raise RuntimeError(
                            "fiducia: reacquired semaphore permit lost fenced authority during renewal"
                        )
                    return SemaphoreHandle(
                        self, key, holder, token, renewed.get("lease_expires_ms"), ttl_ms
                    )
                except Exception:
                    self._cancel_semaphore_wait(key, holder, request_id)
                    raise
            return SemaphoreHandle(
                self, key, holder, token,
                out.get("lease_expires_ms"), ttl_ms
            )
        if out.get("reason") == "limit_mismatch":
            raise RuntimeError(
                "fiducia: semaphore limit mismatch (requested %s, configured %s)"
                % (limit, out.get("limit"))
            )
        if not wait:
            return None

        deadline = _time.monotonic() + max_wait_ms / 1000.0
        attempts = 0
        acquired = False
        try:
            while max_retries is None or attempts < max_retries:
                remaining = deadline - _time.monotonic()
                if remaining <= 0:
                    break
                delay_ms = min(retry_interval_ms * (2 ** min(attempts, 3)), 2000)
                _time.sleep(min(delay_ms / 1000.0, remaining))
                attempts += 1
                retried = self.semaphore_acquire(
                    key,
                    limit,
                    holder=holder,
                    request_id=request_id,
                    ttl_ms=ttl_ms,
                    wait=True,
                    wait_timeout_ms=max_wait_ms,
                )
                out = _output(retried)
                if out.get("acquired"):
                    token = _fencing_token(out, "semaphore permit")
                    renewed = _output(self.semaphore_renew(key, holder, token, ttl_ms))
                    if not renewed.get("renewed"):
                        raise RuntimeError(
                            "fiducia: retry-discovered semaphore permit lost fenced authority during renewal"
                        )
                    acquired = True
                    return SemaphoreHandle(
                        self,
                        key,
                        holder,
                        token,
                        renewed.get("lease_expires_ms"),
                        ttl_ms,
                    )
                if out.get("reason") == "limit_mismatch":
                    raise RuntimeError(
                        "fiducia: semaphore limit mismatch (requested %s, configured %s)"
                        % (limit, out.get("limit"))
                    )
            return None
        finally:
            if not acquired:
                self._cancel_semaphore_wait(key, holder, request_id)

    def _cancel_semaphore_wait(self, key, holder, request_id):
        out = _output(self.semaphore_cancel(key, holder, request_id=request_id))
        if out.get("acquired"):
            token = _fencing_token(out, "raced semaphore permit")
            released = _output(self.semaphore_release(key, holder, token))
            if released.get("released") is False:
                raise RuntimeError(
                    "fiducia: raced semaphore permit could not be released safely"
                )
            return
        if out.get("cancelled") is True:
            return
        raise RuntimeError(
            "fiducia: semaphore cancellation did not establish safety (%s)"
            % out.get("reason", "invalid_response")
        )


def _as_list(key_or_keys):
    return list(key_or_keys) if isinstance(key_or_keys, (list, tuple)) else [key_or_keys]
