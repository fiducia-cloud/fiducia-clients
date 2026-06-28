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

    def __init__(self, client, keys, holder, fencing_token, lease_expires_ms=None):
        self._client = client
        self.keys = keys
        self.holder = holder
        self.fencing_token = fencing_token
        self.lease_expires_ms = lease_expires_ms

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
    def __init__(self, client, key, holder, fencing_token, lease_expires_ms=None):
        self._client = client
        self.key = key
        self.holder = holder
        self.fencing_token = fencing_token
        self.lease_expires_ms = lease_expires_ms

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


def _output(resp):
    return ((resp or {}).get("result") or {}).get("output") or {}


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
        holder = holder or _gen_holder()
        first = self.lock_acquire_many(keys, holder=holder, ttl_ms=ttl_ms, wait=wait)
        out = _output(first)
        if out.get("acquired"):
            return Lock(self, keys, holder, out.get("fencing_token"), out.get("lease_expires_ms"))
        if not wait:
            return None  # try_lock: held now → fail fast

        deadline = _time.monotonic() + max_wait_ms / 1000.0
        attempts = 0
        while max_retries is None or attempts < max_retries:
            attempts += 1
            remaining = deadline - _time.monotonic()
            if remaining <= 0:
                break
            _time.sleep(min(retry_interval_ms / 1000.0, remaining))
            lk = (self.lock_get(keys[0]) or {}).get("lock") or {}
            if lk.get("holder") == holder and lk.get("fencing_token") is not None:
                return Lock(self, keys, holder, lk.get("fencing_token"), lk.get("lease_expires_ms"))
        return None

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
        holder = holder or _gen_holder()
        first = self.semaphore_acquire(key, limit, holder=holder, ttl_ms=ttl_ms, wait=wait)
        out = _output(first)
        if out.get("acquired"):
            return SemaphoreHandle(self, key, holder, out.get("fencing_token"), out.get("lease_expires_ms"))
        if not wait:
            return None

        deadline = _time.monotonic() + max_wait_ms / 1000.0
        attempts = 0
        while max_retries is None or attempts < max_retries:
            attempts += 1
            remaining = deadline - _time.monotonic()
            if remaining <= 0:
                break
            _time.sleep(min(retry_interval_ms / 1000.0, remaining))
            sem = (self.semaphore_get(key) or {}).get("semaphore") or {}
            for slot in sem.get("holders") or []:
                if slot.get("holder") == holder and slot.get("fencing_token") is not None:
                    return SemaphoreHandle(self, key, holder, slot.get("fencing_token"), slot.get("lease_expires_ms"))
        return None


def _as_list(key_or_keys):
    return list(key_or_keys) if isinstance(key_or_keys, (list, tuple)) else [key_or_keys]
