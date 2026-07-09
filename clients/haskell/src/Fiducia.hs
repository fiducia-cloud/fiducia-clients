-- Fiducia HTTP client (Haskell). Deps: http-client + http-client-tls (transport),
-- aeson (JSON), network-uri (percent-encoding). Implements PROTOCOL.md.
--
--   import qualified Fiducia as F
--   c <- F.newClient "https://api.fiducia.cloud"
--   grant <- F.lockAcquire c "orders/checkout" Nothing (Just 30000) True
--   _ <- F.lockRelease c "orders/checkout" "worker-a" 7   -- fencing_token from grant
--
-- Every operation returns the parsed JSON response as an aeson 'Value' (an empty
-- body decodes to 'Null'). On HTTP status >= 300 a 'FiduciaError' is thrown.
--
-- The blocking helpers 'mustLock' \/ 'lock' \/ 'mustSemaphore' \/ 'semaphore'
-- actually block: the server queues a FIFO slot and returns immediately, so they
-- poll 'lockGet' \/ 'semaphoreGet' until the grant is held, throwing 'LockTimeout'
-- when the poll budget ('PollOpts') runs out. 'tryLock' \/ 'trySemaphore' stay a
-- single non-blocking shot.

{-# LANGUAGE OverloadedStrings #-}

module Fiducia
  ( -- * Client
    Client
  , newClient
    -- * Errors
  , FiduciaError(..)
  , LockTimeout(..)
    -- * blocking-acquire poll options
  , PollOpts(..)
  , defaultPollOpts
    -- * misc
  , health
  , status
    -- * locks
  , lockGet
  , lockAcquire
  , lockAcquireMany
  , tryLock
  , mustLock
  , mustLockWith
  , lock
  , lockRelease
    -- * semaphores
  , semaphoreGet
  , semaphoreAcquire
  , trySemaphore
  , mustSemaphore
  , mustSemaphoreWith
  , semaphore
  , semaphoreRelease
    -- * idempotency
  , idempotencyGet
  , idempotencyClaim
  , idempotencyComplete
    -- * reader-writer locks
  , rwAcquireRead
  , rwEndRead
  , rwAcquireWrite
  , rwEndWrite
    -- * config KV
  , kvGet
  , kvPut
  , kvDelete
  , kvList
    -- * rate limiting
  , rateLimitGet
  , rateLimitCheck
    -- * cron & scheduling
  , scheduleGet
  , scheduleUpsert
  , scheduleRecordRun
  , scheduleHistory
    -- * leader election
  , electionGet
  , electionCampaign
  , electionRenew
  , electionResign
    -- * service discovery
  , serviceInstances
  , serviceRegister
  , serviceHeartbeat
  , serviceDeregister
  , serviceList
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (Exception, SomeException, throwIO, try)
import Data.Aeson (ToJSON, Value (..), decode, encode, object, (.=))
import Data.Aeson.Key (Key)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Pair)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Foldable (toList)
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Unique (hashUnique, newUnique)
import Data.Word (Word8)
import GHC.Clock (getMonotonicTimeNSec)
import Network.HTTP.Client
  ( Manager
  , Request
  , RequestBody (RequestBodyLBS)
  , httpLbs
  , managerResponseTimeout
  , method
  , newManager
  , parseRequest
  , redirectCount
  , requestBody
  , requestHeaders
  , responseBody
  , responseStatus
  , responseTimeoutMicro
  )
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types (Method, hContentType, statusCode)
import Network.URI (escapeURIString, isUnreserved)
import Numeric (showHex)
import System.IO (IOMode (ReadMode), withBinaryFile)

-- | A Fiducia HTTP client: a shared connection 'Manager' plus the base URL
-- (trailing slashes trimmed). Build one with 'newClient'.
data Client = Client
  { clientManager :: Manager
  , clientBase :: String
  }

-- | Create a client for the given base URL, e.g. @"https://api.fiducia.cloud"@.
-- The same client (and its connection pool) is safe to share across threads.
-- A conservative 30s response timeout is applied so a stalled server cannot hang
-- a caller forever (these operations do not long-poll).
newClient :: String -> IO Client
newClient baseUrl = do
  mgr <- newManager tlsManagerSettings {managerResponseTimeout = responseTimeoutMicro 30000000}
  pure Client {clientManager = mgr, clientBase = trimTrailingSlashes baseUrl}

-- | Raised on any response with HTTP status >= 300. Carries the numeric status
-- and the parsed JSON body ('Null' when the body was empty).
data FiduciaError = FiduciaError
  { errorStatus :: Int
  , errorBody :: Value
  }
  deriving (Show)

instance Exception FiduciaError

-- | Thrown by the blocking helpers ('mustLock', 'lock', 'mustSemaphore',
-- 'semaphore') when the grant is not held before the poll budget ('maxWaitMs'
-- or 'maxRetries') is exhausted. Carries the key and the holder id that was
-- waited on (the holder is generated when the caller passes 'Nothing').
data LockTimeout = LockTimeout
  { timeoutKey :: Text
  , timeoutHolder :: Text
  , timeoutWaitedMs :: Int
  }
  deriving (Show)

instance Exception LockTimeout

-- | Poll budget for the blocking acquire helpers. Build from 'defaultPollOpts'
-- and override fields as needed, e.g. @defaultPollOpts {maxWaitMs = 5000}@.
data PollOpts = PollOpts
  { maxWaitMs :: Int -- ^ total wall-clock budget to keep polling, in ms
  , retryIntervalMs :: Int -- ^ delay between polls, in ms
  , maxRetries :: Maybe Int -- ^ optional cap on the number of polls
  }
  deriving (Show)

-- | Reference defaults: @maxWaitMs = 30000@, @retryIntervalMs = 250@,
-- @maxRetries = Nothing@ (matches the other Fiducia clients).
defaultPollOpts :: PollOpts
defaultPollOpts = PollOpts {maxWaitMs = 30000, retryIntervalMs = 250, maxRetries = Nothing}

-- --- misc ---

-- | Liveness probe: @GET \/healthz@.
health :: Client -> IO Value
health c = request c "GET" "/healthz" Nothing

-- | Per-shard consensus status: @GET \/v1\/status@.
status :: Client -> IO Value
status c = request c "GET" "/v1/status" Nothing

-- --- locks ---

-- | Inspect a lock member key (holder, held union, FIFO wait queue).
lockGet :: Client -> Text -> IO Value
lockGet c key = request c "GET" ("/v1/locks?key=" ++ enc key) Nothing

-- | Acquire a single-key lock. @wait@ = False makes it a non-blocking try-lock.
lockAcquire :: Client -> Text -> Maybe Text -> Maybe Int -> Bool -> IO Value
lockAcquire c key holder ttlMs wait =
  request c "POST" "/v1/locks/acquire" $
    body (["key" .= key] ++ opt "holder" holder ++ opt "ttl_ms" ttlMs ++ ["wait" .= wait])

-- | Multi-key UNION lock: all-or-nothing across the whole set of keys.
lockAcquireMany :: Client -> [Text] -> Maybe Text -> Maybe Int -> Bool -> IO Value
lockAcquireMany c keys holder ttlMs wait =
  request c "POST" "/v1/locks/acquire" $
    body (["keys" .= keys] ++ opt "holder" holder ++ opt "ttl_ms" ttlMs ++ ["wait" .= wait])

-- | Non-blocking acquire ('lockAcquire' with @wait = False@).
tryLock :: Client -> Text -> Maybe Text -> Maybe Int -> IO Value
tryLock c key holder ttlMs = lockAcquire c key holder ttlMs False

-- | Blocking acquire: acquire with @wait = True@, then POLL 'lockGet' until the
-- lock is actually held. The server does not hold the connection on @wait@ — it
-- reserves a FIFO slot and returns immediately — so a client-side poll is what
-- makes this block. Uses 'defaultPollOpts'; throws 'LockTimeout' if the grant is
-- not obtained within the budget. When @holder@ is 'Nothing' a stable id is
-- generated (and @ttl_ms@ defaults to 60000). Returns a held-grant object
-- carrying @holder@, @fencing_token@ (+ @lease_expires_ms@) so the caller can
-- 'lockRelease' it — note the @holder@ may have been generated for you.
mustLock :: Client -> Text -> Maybe Text -> Maybe Int -> IO Value
mustLock c = mustLockWith c defaultPollOpts

-- | 'mustLock' with an explicit poll budget.
mustLockWith :: Client -> PollOpts -> Text -> Maybe Text -> Maybe Int -> IO Value
mustLockWith c opts key mHolder ttlMs = do
  holder <- maybe genHolder pure mHolder
  resp <- lockAcquire c key (Just holder) (Just (fromMaybe defaultLeaseMs ttlMs)) True
  let out = output resp
  if field "acquired" out == Just (Bool True)
    then pure (grantFromOutput holder out)
    else pollUntilHeld opts key holder $ do
      lk <- lockGet c key
      pure (heldGrant holder (fromMaybe Null (field "lock" lk)))

-- | Alias for 'mustLock'.
lock :: Client -> Text -> Maybe Text -> Maybe Int -> IO Value
lock = mustLock

-- | Release the whole grant by its fencing token. The @key@ is accepted for
-- symmetry with 'lockAcquire' but is not sent in the body.
lockRelease :: Client -> Text -> Text -> Int -> IO Value
lockRelease c _key holder fencingToken =
  request c "POST" "/v1/locks/release" $
    body ["holder" .= holder, "fencing_token" .= fencingToken]

-- --- semaphores ---

-- | Inspect a semaphore (limit, holders, free permits, queue).
semaphoreGet :: Client -> Text -> IO Value
semaphoreGet c key = request c "GET" ("/v1/semaphores?key=" ++ enc key) Nothing

-- | Take a permit of a counting semaphore (up to @limit@ holders).
semaphoreAcquire :: Client -> Text -> Int -> Maybe Text -> Maybe Int -> Bool -> IO Value
semaphoreAcquire c key limit holder ttlMs wait =
  request c "POST" "/v1/semaphores/acquire" $
    body (["key" .= key] ++ opt "holder" holder ++ opt "ttl_ms" ttlMs ++ ["limit" .= limit, "wait" .= wait])

-- | Non-blocking permit acquire ('semaphoreAcquire' with @wait = False@).
trySemaphore :: Client -> Text -> Int -> Maybe Text -> Maybe Int -> IO Value
trySemaphore c key limit holder ttlMs = semaphoreAcquire c key limit holder ttlMs False

-- | Blocking permit acquire ('semaphoreAcquire' with @wait = True@).
mustSemaphore :: Client -> Text -> Int -> Maybe Text -> Maybe Int -> IO Value
mustSemaphore c key limit holder ttlMs = semaphoreAcquire c key limit holder ttlMs True

-- | Alias for 'mustSemaphore'.
semaphore :: Client -> Text -> Int -> Maybe Text -> Maybe Int -> IO Value
semaphore = mustSemaphore

-- | Return one permit (admits the next FIFO waiter).
semaphoreRelease :: Client -> Text -> Text -> Int -> IO Value
semaphoreRelease c key holder fencingToken =
  request c "POST" "/v1/semaphores/release" $
    body ["key" .= key, "holder" .= holder, "fencing_token" .= fencingToken]

-- --- idempotency ---

-- | Inspect an active idempotency record.
idempotencyGet :: Client -> Text -> IO Value
idempotencyGet c key = request c "GET" ("/v1/idempotency?key=" ++ enc key) Nothing

-- | Claim an idempotency key; first claimant wins until TTL expiry. @metadata@
-- is an arbitrary JSON object.
idempotencyClaim :: Client -> Text -> Maybe Text -> Maybe Int -> Maybe Text -> Maybe Value -> IO Value
idempotencyClaim c key owner ttlMs ttl metadata =
  request c "POST" "/v1/idempotency/claim" $
    body (["key" .= key] ++ opt "owner" owner ++ opt "ttl_ms" ttlMs ++ opt "ttl" ttl ++ opt "metadata" metadata)

-- | Mark a claimed key complete and optionally store a replayable @result@
-- (an arbitrary JSON object).
idempotencyComplete :: Client -> Text -> Text -> Int -> Maybe Value -> IO Value
idempotencyComplete c key owner fencingToken result =
  request c "POST" "/v1/idempotency/complete" $
    body (["key" .= key, "owner" .= owner, "fencing_token" .= fencingToken] ++ opt "result" result)

-- --- reader-writer locks ---

-- | Acquire a shared (read) lock.
rwAcquireRead :: Client -> Text -> Maybe Int -> Bool -> IO Value
rwAcquireRead c key ttlMs wait =
  request c "POST" ("/v1/rw/" ++ enc key ++ "/read") $
    body (opt "ttl_ms" ttlMs ++ ["wait" .= wait])

-- | Release a shared (read) lock by its @lock_id@.
rwEndRead :: Client -> Text -> Text -> IO Value
rwEndRead c key lockId =
  request c "POST" ("/v1/rw/" ++ enc key ++ "/read/end") $
    body ["lock_id" .= lockId]

-- | Acquire an exclusive (write) lock.
rwAcquireWrite :: Client -> Text -> Maybe Int -> Bool -> IO Value
rwAcquireWrite c key ttlMs wait =
  request c "POST" ("/v1/rw/" ++ enc key ++ "/write") $
    body (opt "ttl_ms" ttlMs ++ ["wait" .= wait])

-- | Release an exclusive (write) lock by its @lock_id@.
rwEndWrite :: Client -> Text -> Text -> IO Value
rwEndWrite c key lockId =
  request c "POST" ("/v1/rw/" ++ enc key ++ "/write/end") $
    body ["lock_id" .= lockId]

-- --- config KV ---

-- | Read a config key.
kvGet :: Client -> Text -> IO Value
kvGet c key = request c "GET" ("/v1/kv?key=" ++ enc key) Nothing

-- | Write a config key. @prevRevision@ is a compare-and-swap guard
-- (@Just 0@ = must-not-exist). @value@ is an arbitrary JSON value.
kvPut :: Client -> Text -> Value -> Maybe Int -> Maybe Int -> IO Value
kvPut c key value ttlMs prevRevision =
  request c "PUT" ("/v1/kv?key=" ++ enc key) $
    body (["value" .= value] ++ opt "ttl_ms" ttlMs ++ opt "prev_revision" prevRevision)

-- | Delete a config key.
kvDelete :: Client -> Text -> IO Value
kvDelete c key = request c "DELETE" ("/v1/kv?key=" ++ enc key) Nothing

-- | List config keys under a prefix.
kvList :: Client -> Text -> IO Value
kvList c prefix = request c "GET" ("/v1/kv?prefix=" ++ enc prefix) Nothing

-- --- rate limiting ---

-- | Current limiter state for a tenant/key.
rateLimitGet :: Client -> Text -> Text -> IO Value
rateLimitGet c tenant key =
  request c "GET" ("/v1/rate-limit/" ++ enc tenant ++ "/" ++ enc key) Nothing

-- | Atomic check-and-decrement. @algorithm@ is @token_bucket@ or
-- @sliding_window@; returns @{allowed, remaining}@.
rateLimitCheck :: Client -> Text -> Text -> Text -> Int -> Int -> Maybe Double -> Maybe Int -> IO Value
rateLimitCheck c tenant key algorithm limit windowMs refillPerSecond cost =
  request c "POST" ("/v1/rate-limit/" ++ enc tenant ++ "/" ++ enc key ++ "/check") $
    body
      ( ["algorithm" .= algorithm, "limit" .= limit, "window_ms" .= windowMs]
          ++ opt "refill_per_second" refillPerSecond
          ++ opt "cost" cost
      )

-- --- cron & scheduling ---

-- | Read a schedule definition.
scheduleGet :: Client -> Text -> IO Value
scheduleGet c name = request c "GET" ("/v1/cron/schedules/" ++ enc name) Nothing

-- | Create/update a schedule. @target@ is an arbitrary JSON object, e.g.
-- @{kind: "webhook", url: "..."}@. Supply exactly one of @cron@ / @oneShotAtMs@.
scheduleUpsert :: Client -> Text -> Value -> Maybe Text -> Maybe Int -> Maybe Text -> Maybe Int -> IO Value
scheduleUpsert c name target cron oneShotAtMs delivery maxRetries =
  request c "PUT" ("/v1/cron/schedules/" ++ enc name) $
    body
      ( ["target" .= target]
          ++ opt "cron" cron
          ++ opt "one_shot_at_ms" oneShotAtMs
          ++ opt "delivery" delivery
          ++ opt "max_retries" maxRetries
      )

-- | Record a fire; a duplicate @fireId@ is deduped (exactly-once).
scheduleRecordRun :: Client -> Text -> Text -> Maybe Int -> IO Value
scheduleRecordRun c name fireId firedAtMs =
  request c "POST" ("/v1/cron/schedules/" ++ enc name ++ "/runs") $
    body (["fire_id" .= fireId] ++ opt "fired_at_ms" firedAtMs)

-- | Recent run history for a schedule.
scheduleHistory :: Client -> Text -> IO Value
scheduleHistory c name = request c "GET" ("/v1/cron/schedules/" ++ enc name ++ "/history") Nothing

-- --- leader election ---

-- | Observe the current holder of a named election.
electionGet :: Client -> Text -> IO Value
electionGet c name = request c "GET" ("/v1/elections/" ++ enc name) Nothing

-- | Campaign for leadership; wins if currently unheld. @metadata@ is an
-- arbitrary JSON object. Returns a fencing token on win.
electionCampaign :: Client -> Text -> Text -> Int -> Maybe Value -> IO Value
electionCampaign c name candidate ttlMs metadata =
  request c "POST" ("/v1/elections/" ++ enc name ++ "/campaign") $
    body (["candidate" .= candidate, "ttl_ms" .= ttlMs] ++ opt "metadata" metadata)

-- | Extend the lease; requires the held fencing token.
electionRenew :: Client -> Text -> Text -> Int -> IO Value
electionRenew c name candidate fencingToken =
  request c "POST" ("/v1/elections/" ++ enc name ++ "/renew") $
    body ["candidate" .= candidate, "fencing_token" .= fencingToken]

-- | Step down; requires the held fencing token.
electionResign :: Client -> Text -> Text -> Int -> IO Value
electionResign c name candidate fencingToken =
  request c "POST" ("/v1/elections/" ++ enc name ++ "/resign") $
    body ["candidate" .= candidate, "fencing_token" .= fencingToken]

-- --- service discovery ---

-- | List live instances of a service.
serviceInstances :: Client -> Text -> IO Value
serviceInstances c service = request c "GET" ("/v1/services/" ++ enc service) Nothing

-- | Register/refresh an instance with a TTL lease and optional @metadata@.
serviceRegister :: Client -> Text -> Text -> Text -> Int -> Maybe Value -> IO Value
serviceRegister c service instanceId address ttlMs metadata =
  request c "PUT" ("/v1/services/" ++ enc service ++ "/instances/" ++ enc instanceId) $
    body (["address" .= address, "ttl_ms" .= ttlMs] ++ opt "metadata" metadata)

-- | Renew an instance lease before it expires.
serviceHeartbeat :: Client -> Text -> Text -> Maybe Int -> IO Value
serviceHeartbeat c service instanceId ttlMs =
  request c "POST" ("/v1/services/" ++ enc service ++ "/instances/" ++ enc instanceId ++ "/heartbeat") $
    body (opt "ttl_ms" ttlMs)

-- | Remove an instance from the registry.
serviceDeregister :: Client -> Text -> Text -> IO Value
serviceDeregister c service instanceId =
  request c "DELETE" ("/v1/services/" ++ enc service ++ "/instances/" ++ enc instanceId) Nothing

-- | List all registered services.
serviceList :: Client -> IO Value
serviceList c = request c "GET" "/v1/services" Nothing

-- --- internals ---

-- | Percent-encode a string for use as a path segment or query value. Every
-- non-unreserved character (including @\/@) is escaped, matching @encodeURIComponent@.
enc :: Text -> String
enc = escapeURIString isUnreserved . T.unpack

-- | Wrap request-body pairs into @Just@ a JSON object.
body :: [Pair] -> Maybe Value
body = Just . object

-- | A body field included only when the caller supplied a value (CAS-safe:
-- omitted keys are never sent as null).
opt :: (ToJSON a) => Key -> Maybe a -> [Pair]
opt k = maybe [] (\v -> [k .= v])

trimTrailingSlashes :: String -> String
trimTrailingSlashes = reverse . dropWhile (== '/') . reverse

-- | Perform one HTTP request and decode the JSON response, throwing
-- 'FiduciaError' on status >= 300.
request :: Client -> Method -> String -> Maybe Value -> IO Value
request c httpMethod path mbody = do
  initReq <- parseRequest (clientBase c ++ path)
  -- redirectCount = 0: never auto-follow 3xx. Following a redirect on a mutating
  -- POST/PUT/DELETE could re-submit the operation (duplicating a lock grant or
  -- FIFO queue slot); the load balancer already routes to the shard leader. A 3xx
  -- is >= 300 and so surfaces as a 'FiduciaError' carrying its status and body.
  let req = (initReq {method = httpMethod, redirectCount = 0})
  resp <- httpLbs (applyBody mbody req) (clientManager c)
  let code = statusCode (responseStatus resp)
      raw = responseBody resp
      val = if LBS.null raw then Null else fromMaybe Null (decode raw)
  if code >= 300
    then throwIO (FiduciaError code val)
    else pure val

-- | Attach a JSON body + Content-Type header when one is present.
applyBody :: Maybe Value -> Request -> Request
applyBody Nothing req = req
applyBody (Just v) req =
  req
    { requestHeaders = (hContentType, "application/json") : requestHeaders req
    , requestBody = RequestBodyLBS (encode v)
    }
