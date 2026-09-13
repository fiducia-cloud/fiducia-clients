import assert from "node:assert/strict";
import test from "node:test";

import {
  applyServiceDiscoveryEvent,
  createServiceDiscoveryReplica,
  type ServiceDiscoveryReplica,
  type ServiceInstance,
  type ServiceWatchEnvelope,
} from "./service-discovery.ts";

function instance(id: string, leaseExpiresMs = 10_000): ServiceInstance {
  return {
    instance_id: id,
    address: `https://${id}.internal`,
    lease_expires_ms: leaseExpiresMs,
    metadata: { region: "us-east", version: id },
  };
}

function snapshot(
  service: string,
  instances: readonly ServiceInstance[],
  reason = "initial",
  revision?: number,
): ServiceWatchEnvelope {
  return {
    event: "snapshot",
    ...(revision === undefined ? {} : { id: String(revision) }),
    data: {
      scope: "service",
      kind: "snapshot",
      service,
      reason,
      authoritative: true,
      trigger_revision: revision ?? null,
      instances,
    },
  };
}

function change(
  service: string,
  kind: "register" | "heartbeat" | "deregister",
  revision: number,
): ServiceWatchEnvelope {
  return {
    event: kind,
    id: String(revision),
    data: {
      scope: "service",
      kind,
      key: service,
      revision,
      detail: kind === "deregister" ? null : instance("api-1"),
    },
  };
}

test("replica starts fail-closed until an authoritative snapshot arrives", () => {
  const initial = createServiceDiscoveryReplica(" api ");
  assert.equal(initial.service, "api");
  assert.equal(initial.synchronized, false);
  assert.equal(initial.needsResync, true);
  assert.deepEqual(initial.instances, []);
  assert.throws(() => createServiceDiscoveryReplica("  "), /non-empty service name/);

  const applied = applyServiceDiscoveryEvent(
    initial,
    snapshot("api", [instance("api-2"), instance("api-1")]),
  );
  assert.equal(applied.kind, "snapshot");
  assert.equal(applied.state.synchronized, true);
  assert.equal(applied.state.needsResync, false);
  assert.deepEqual(
    applied.state.instances.map((entry) => entry.instance_id),
    ["api-1", "api-2"],
  );
  assert.ok(Object.isFrozen(applied.state));
  assert.ok(Object.isFrozen(applied.state.instances));
  assert.ok(Object.isFrozen(applied.state.instances[0].metadata));
});

test("committed mutation events are hints until their authoritative snapshot", () => {
  let state = applyServiceDiscoveryEvent(
    createServiceDiscoveryReplica("api"),
    snapshot("api", [instance("api-1")], "initial", 10),
  ).state;

  const hinted = applyServiceDiscoveryEvent(state, change("api", "heartbeat", 12));
  assert.equal(hinted.kind, "hint");
  assert.equal(hinted.state.synchronized, false);
  assert.equal(hinted.state.needsResync, false);
  assert.equal(hinted.state.lastObservedRevision, 12);
  assert.deepEqual(hinted.state.instances, state.instances, "a hint must not rewrite routing state");

  const confirmed = applyServiceDiscoveryEvent(
    hinted.state,
    snapshot("api", [instance("api-1", 20_000)], "change", 12),
  );
  assert.equal(confirmed.kind, "snapshot");
  assert.equal(confirmed.state.synchronized, true);
  assert.equal(confirmed.state.lastSnapshotRevision, 12);
  assert.equal(confirmed.state.instances[0].lease_expires_ms, 20_000);
});

test("shared-shard revision gaps are allowed while stale and duplicate changes are ignored", () => {
  let state = applyServiceDiscoveryEvent(
    createServiceDiscoveryReplica("api"),
    snapshot("api", [], "initial", 2),
  ).state;

  const gapped = applyServiceDiscoveryEvent(state, change("api", "register", 19));
  assert.equal(gapped.kind, "hint");
  assert.equal(gapped.state.needsResync, false);
  assert.equal(gapped.state.lastObservedRevision, 19);

  for (const revision of [19, 18, 2]) {
    const ignored = applyServiceDiscoveryEvent(
      gapped.state,
      change("api", "heartbeat", revision),
    );
    assert.equal(ignored.kind, "ignored");
    assert.equal(ignored.reason, "stale_or_duplicate_change");
    assert.strictEqual(ignored.state, gapped.state);
  }

  state = applyServiceDiscoveryEvent(
    gapped.state,
    snapshot("api", [instance("api-1")], "change", 19),
  ).state;
  assert.equal(state.synchronized, true);
});

test("lag recovery and lease reconciliation snapshots replace the complete instance set", () => {
  let state = applyServiceDiscoveryEvent(
    createServiceDiscoveryReplica("api"),
    snapshot("api", [instance("stale")], "initial", 7),
  ).state;

  state = applyServiceDiscoveryEvent(state, change("api", "register", 11)).state;
  const recovered = applyServiceDiscoveryEvent(
    state,
    snapshot("api", [instance("current")], "lagged"),
  );
  assert.equal(recovered.kind, "snapshot");
  assert.equal(recovered.state.synchronized, true);
  assert.equal(recovered.state.needsResync, false);
  assert.equal(recovered.state.lastObservedRevision, 11);
  assert.deepEqual(recovered.state.instances.map((entry) => entry.instance_id), ["current"]);

  const expired = applyServiceDiscoveryEvent(
    recovered.state,
    snapshot("api", [], "lease_reconcile"),
  );
  assert.equal(expired.kind, "snapshot");
  assert.deepEqual(expired.state.instances, []);
});

test("malformed or contradictory events fail closed and request resynchronization", () => {
  const synchronized = applyServiceDiscoveryEvent(
    createServiceDiscoveryReplica("api"),
    snapshot("api", [instance("api-1")], "initial", 4),
  ).state;

  const cases: Array<[ServiceWatchEnvelope, string]> = [
    [{ event: "snapshot", data: "not-json-object" }, "non_object_payload"],
    [{
      event: "snapshot",
      data: {
        scope: "service",
        kind: "snapshot",
        service: "api",
        authoritative: false,
        trigger_revision: null,
        instances: [],
      },
    }, "non_authoritative_snapshot"],
    [{
      event: "register",
      id: "5",
      data: { scope: "service", kind: "heartbeat", key: "api", revision: 5 },
    }, "event_kind_mismatch"],
    [{
      event: "register",
      id: "6",
      data: { scope: "service", kind: "register", key: "api", revision: 5 },
    }, "change_revision_mismatch"],
    [{
      event: "snapshot",
      data: {
        scope: "service",
        kind: "snapshot",
        service: "api",
        authoritative: true,
        trigger_revision: null,
        instances: [instance("duplicate"), instance("duplicate")],
      },
    }, "invalid_snapshot_instances"],
  ];

  for (const [event, reason] of cases) {
    const result = applyServiceDiscoveryEvent(synchronized, event);
    assert.equal(result.kind, "resync_required");
    assert.equal(result.reason, reason);
    assert.equal(result.state.synchronized, false);
    assert.equal(result.state.needsResync, true);
    assert.deepEqual(result.state.instances, synchronized.instances);
  }
});

test("wrong-service deltas are ignored but a wrong-service snapshot fails closed", () => {
  const state: ServiceDiscoveryReplica = applyServiceDiscoveryEvent(
    createServiceDiscoveryReplica("api"),
    snapshot("api", [], "initial", 3),
  ).state;

  const unrelated = applyServiceDiscoveryEvent(state, change("worker", "register", 4));
  assert.equal(unrelated.kind, "ignored");
  assert.equal(unrelated.reason, "different_service");
  assert.strictEqual(unrelated.state, state);

  const corruptSnapshot = applyServiceDiscoveryEvent(
    state,
    snapshot("worker", [instance("worker-1")], "initial", 4),
  );
  assert.equal(corruptSnapshot.kind, "resync_required");
  assert.equal(corruptSnapshot.reason, "snapshot_service_mismatch");
});

test("an unavailable event preserves the last known set but makes it unroutable as fresh state", () => {
  const state = applyServiceDiscoveryEvent(
    createServiceDiscoveryReplica("api"),
    snapshot("api", [instance("api-1")]),
  ).state;

  const unavailable = applyServiceDiscoveryEvent(state, {
    event: "unavailable",
    data: {
      scope: "service",
      kind: "unavailable",
      service: "api",
      retryable: true,
    },
  });
  assert.equal(unavailable.kind, "resync_required");
  assert.equal(unavailable.reason, "upstream_unavailable");
  assert.equal(unavailable.state.synchronized, false);
  assert.equal(unavailable.state.needsResync, true);
  assert.deepEqual(unavailable.state.instances, state.instances);
});

test("a stale post-hint snapshot cannot regress membership", () => {
  let state = applyServiceDiscoveryEvent(
    createServiceDiscoveryReplica("api"),
    snapshot("api", [instance("old")], "initial", 7),
  ).state;
  state = applyServiceDiscoveryEvent(state, change("api", "register", 9)).state;

  const stale = applyServiceDiscoveryEvent(
    state,
    snapshot("api", [instance("older")], "change", 8),
  );
  assert.equal(stale.kind, "ignored");
  assert.equal(stale.reason, "stale_snapshot");
  assert.strictEqual(stale.state, state);
  assert.equal(stale.state.synchronized, false);
});
