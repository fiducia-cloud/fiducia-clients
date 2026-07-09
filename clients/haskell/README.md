# fiducia-client (Haskell)

A thin, dependency-light Haskell client for the [fiducia.cloud](https://github.com/fiducia-cloud/fiducia-clients)
HTTP API. Transport is `http-client` + `http-client-tls`; JSON is `aeson`.
Every operation returns the parsed response as an aeson `Value`.

## Install

Add to your `build-depends`:

```
build-depends: fiducia-client
```

The library exposes a single module, `Fiducia`.

## Usage

```haskell
{-# LANGUAGE OverloadedStrings #-}
import qualified Fiducia as F
import Control.Exception (try)
import Data.Aeson (Value)

main :: IO ()
main = do
  c <- F.newClient "https://api.fiducia.cloud"

  -- locks (wait = True blocks; wait = False is a try-lock)
  grant <- F.lockAcquire c "orders/checkout" Nothing (Just 30000) True
  -- ... do work, pull the fencing_token out of `grant` ...
  _ <- F.lockRelease c "orders/checkout" "worker-a" 7

  -- config KV (value is any JSON; prev_revision is a CAS guard)
  _ <- F.kvPut c "feature/flags" "on" Nothing (Just 0)
  flags <- F.kvGet c "feature/flags"

  -- errors: HTTP status >= 300 throws a FiduciaError
  r <- try (F.status c) :: IO (Either F.FiduciaError Value)
  print r
```

Optional parameters are `Maybe` — pass `Nothing` to omit them (omitted fields are
never sent, which matters for compare-and-swap semantics). Arbitrary-JSON
parameters (`metadata`, `result`, `target`, KV `value`) take an aeson `Value`.

## Operations

`health`, `status`; `lockGet`, `lockAcquire`, `lockAcquireMany`, `tryLock`,
`mustLock`, `lock`, `lockRelease`; `semaphoreGet`, `semaphoreAcquire`,
`trySemaphore`, `mustSemaphore`, `semaphore`, `semaphoreRelease`;
`idempotencyGet`, `idempotencyClaim`, `idempotencyComplete`; `rwAcquireRead`,
`rwEndRead`, `rwAcquireWrite`, `rwEndWrite`; `kvGet`, `kvPut`, `kvDelete`,
`kvList`; `rateLimitGet`, `rateLimitCheck`; `scheduleGet`, `scheduleUpsert`,
`scheduleRecordRun`, `scheduleHistory`; `electionGet`, `electionCampaign`,
`electionRenew`, `electionResign`; `serviceInstances`, `serviceRegister`,
`serviceHeartbeat`, `serviceDeregister`, `serviceList`.

## License

UNLICENSED / proprietary. See [LICENSE](./LICENSE).
