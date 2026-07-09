# Fiducia client (MATLAB)

A thin, dependency-light MATLAB client for the [fiducia.cloud](https://github.com/fiducia-cloud/fiducia-clients)
coordination API. It is a single class, `Fiducia.m`, built entirely on
base-MATLAB `matlab.net.http` for transport and `jsonencode` / `jsondecode` for
JSON. No toolboxes or third-party packages are required.

- **Version:** 0.1.0
- **Requires:** MATLAB R2019b or newer (uses `arguments` blocks).

## Install

`Fiducia.m` is self-contained. Pick whichever fits your workflow:

- **Add the folder to your path** (simplest):

  ```matlab
  addpath('/path/to/fiducia-clients/clients/matlab');
  % or save it permanently:
  savepath;
  ```

- **Install from MATLAB File Exchange / Add-On Explorer.** In MATLAB open
  **Home > Add-Ons > Get Add-Ons**, search for "Fiducia", and click **Add**.
  The Add-On Explorer installs the release and puts `Fiducia.m` on your path
  automatically. See [Distribution](#distribution-and-file-exchange-linking).

Once the folder is on your path, `Fiducia` is available like any built-in class.

## Usage

```matlab
c = Fiducia('https://api.fiducia.cloud');

% Connect + response timeout in seconds. Default 30; set [] for the matlab.net.http default.
c.RequestTimeout = 10;

% Health / status
c.health();
c.status();

% Acquire a lock (blocking), read the fencing token, release it.
lk = c.lockAcquire('orders/checkout', 'holder', 'worker-a', 'ttl_ms', 30000);
token = lk.result.output.fencing_token;
c.lockRelease('orders/checkout', 'worker-a', token);

% Non-blocking try. tryLock/mustLock/lock just flip the wait flag.
r = c.tryLock('orders/checkout', 'ttl_ms', 5000);

% A union lock over several keys at once.
c.lockAcquireMany({'a', 'b', 'c'}, 'ttl_ms', 30000);

% Semaphores (limit is required and positional).
s = c.semaphoreAcquire('pool/db', 5, 'ttl_ms', 30000);
c.semaphoreRelease('pool/db', s.result.output.holder, s.result.output.fencing_token);

% Config KV
c.kvPut('config/theme', 'dark', 'ttl_ms', 60000);
v = c.kvGet('config/theme');
c.kvList('config/');
c.kvDelete('config/theme');

% Idempotency, with an arbitrary JSON object as metadata / result.
c.idempotencyClaim('job-42', 'owner', 'worker-a', 'metadata', struct('attempt', 1));
c.idempotencyComplete('job-42', 'worker-a', token, 'result', struct('ok', true));

% Cron: target and delivery are arbitrary JSON objects (structs).
c.scheduleUpsert('nightly', struct('kind', 'webhook', 'url', 'https://x/y'), 'cron', '0 3 * * *');
```

On MATLAB R2021a and newer you can also use `name=value` call syntax:

```matlab
lk = c.lockAcquire('orders/checkout', ttl_ms=30000, wait=true);
```

### Return values

Every method returns the decoded JSON response: a `struct` for a JSON object, a
cell/array for a JSON array, and `[]` for an empty body (`jsondecode`
conventions). Reach into nested fields directly, e.g.
`lk.result.output.fencing_token`.

### Optional parameters

Parameters marked optional in the protocol are sent **only** when you pass them
(nulls are omitted, which matters for compare-and-set semantics). Keys, names,
services, tenants, and prefixes interpolated into a path or query are
percent-encoded automatically.

### Errors

On any HTTP status `>= 300` the client raises an `MException` with the
identifier `fiducia:httpError`. Its message carries the numeric status and the
raw response body:

```matlab
try
    c.lockAcquire('orders/checkout', 'wait', false);
catch err
    if strcmp(err.identifier, 'fiducia:httpError')
        disp(err.message);   % e.g. "fiducia: HTTP 409: {"error":"held"}"
    else
        rethrow(err);
    end
end
```

## Method surface

Method names use MATLAB's camelCase convention; the canonical concept names are
preserved. `health`, `status`, `lockGet`, `lockAcquire`, `lockAcquireMany`,
`tryLock`, `mustLock`, `lock`, `lockRelease`, `semaphoreGet`,
`semaphoreAcquire`, `trySemaphore`, `mustSemaphore`, `semaphore`,
`semaphoreRelease`, `idempotencyGet`, `idempotencyClaim`, `idempotencyComplete`,
`rwAcquireRead`, `rwEndRead`, `rwAcquireWrite`, `rwEndWrite`, `kvGet`, `kvPut`,
`kvDelete`, `kvList`, `rateLimitGet`, `rateLimitCheck`, `scheduleGet`,
`scheduleUpsert`, `scheduleRecordRun`, `scheduleHistory`, `electionGet`,
`electionCampaign`, `electionRenew`, `electionResign`, `serviceInstances`,
`serviceRegister`, `serviceHeartbeat`, `serviceDeregister`, `serviceList`.

## Distribution and File Exchange linking

Releases are cut from this repository. The publisher tags
`clients/matlab/v${PACKAGE_VERSION}` and creates a GitHub Release that attaches
`Fiducia.m`:

```sh
clients/matlab/publish.sh            # dry-run: prints the release command
clients/matlab/publish.sh --release  # tags and creates the GitHub release
```

The MATLAB **File Exchange** entry is linked to the GitHub repository so each
GitHub release is mirrored automatically:

1. On the File Exchange submission page choose **"Link to a GitHub repository"**
   and point it at `fiducia-cloud/fiducia-clients`.
2. File Exchange imports the repo and tracks its releases; publishing a new
   `clients/matlab/v*` GitHub release publishes a matching File Exchange version.
3. Users then install through the in-product **Add-On Explorer**
   (**Get Add-Ons**), which adds `Fiducia.m` to their path.

## License

`UNLICENSED` / proprietary. See [LICENSE.txt](LICENSE.txt).
