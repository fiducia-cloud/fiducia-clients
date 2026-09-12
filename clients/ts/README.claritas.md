# Fiducia local Claritas metric views (DEN-2308)

Import `createFiduciaMetricViews` from `@fiducia/client/claritas.ts`, following
this package's existing source-TypeScript runtime/toolchain convention. Supply
`createLocalVisualizationClient(createVisualizationSdk())` from Claritas clients
and public core. The adapter calls upstream cohortTrends/individualTrend/trendSvg;
it does not copy algorithms, fetch metrics, add API routes, or require a server.

Local input fields: nodeId, region, metric, unit, at, value. Supported measurement
labels: request_latency_ms (ms), replication_lag_ms (ms), queue_depth (count).
These are adapter labels, not claims of existing telemetry collector coverage.
One metric/unit per call is required. Only entityId/cohortId/at/value reach
Claritas; never use lock keys, KV values, lease credentials or signed URLs as IDs.
Inputs must already be authorized. Means are node-balanced, not pooled latency
percentiles, queue totals or duration-weighted statistics. Errors propagate,
missing is not zero, and no synthetic fallback is installed.

Pin public core `b0082e5ee2598c54a013f217cff8bac7e0ce5765` (PR #3) and Claritas
clients `3eec600c294b56b3b121c6b41802d6802a67b733` (PR #8) through the approved
Zed/artifact path. These are source review candidates, not registry publication.
No new mutable dependency, generated operation or wire schema is added.

Six focused tests: `node --experimental-strip-types --test test/claritas.test.mjs`.
Two real-core/SDK tests: set CLARITAS_CORE_MODULE and CLARITAS_CLIENT_MODULE to
absolute built entry-point paths and run
`node --experimental-strip-types --test integration/claritas.integration.mjs`.
Missing artifacts fail; tests never skip/fetch. Existing package tests and
contract/prepublish guards are preserved, and the focused tests join npm test.

Remaining gates: generator drift and the full native/package matrix, current
head CI/review, approved source/artifact resolution, real metrics/dashboard
wiring and cross-runtime parity. Local tests do not certify a live cluster or
production dashboard. The host owns tenant permissions, release thresholds,
exports and anti-differencing policy; browser suppression is not authorization.
