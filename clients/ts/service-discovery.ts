/**
 * Fail-closed reducer for `/v1/services/{service}/watch`.
 *
 * Fiducia's service registry is authoritative Raft state. The SSE stream is a
 * bounded acceleration channel: mutation events are low-latency hints and every
 * authoritative `snapshot` replaces local membership. Consumers must not build
 * routing state solely by replaying register/heartbeat/deregister events because
 * a disconnected or lagged subscriber may have missed one.
 */

import type { ServiceInstance } from "@fiducia/interfaces/typescript";

export type { ServiceInstance } from "@fiducia/interfaces/typescript";

export interface ServiceWatchEnvelope {
  readonly event?: string;
  readonly id?: string;
  readonly data: unknown;
}

export interface ServiceDiscoveryReplica {
  readonly service: string;
  readonly instances: readonly ServiceInstance[];
  readonly synchronized: boolean;
  readonly needsResync: boolean;
  readonly lastObservedRevision?: number;
  readonly lastSnapshotRevision?: number;
}

export type ServiceDiscoveryApplyKind =
  | "snapshot"
  | "hint"
  | "ignored"
  | "resync_required";

export interface ServiceDiscoveryApplyResult {
  readonly kind: ServiceDiscoveryApplyKind;
  readonly state: ServiceDiscoveryReplica;
  readonly reason?: string;
}

const CHANGE_KINDS = new Set(["register", "heartbeat", "deregister"]);

export function createServiceDiscoveryReplica(service: string): ServiceDiscoveryReplica {
  const normalized = service.trim();
  if (!normalized) {
    throw new TypeError("fiducia: service discovery requires a non-empty service name");
  }
  return Object.freeze({
    service: normalized,
    instances: Object.freeze([]),
    synchronized: false,
    needsResync: true,
  });
}

export function applyServiceDiscoveryEvent(
  current: ServiceDiscoveryReplica,
  envelope: ServiceWatchEnvelope,
): ServiceDiscoveryApplyResult {
  const payload = asRecord(envelope.data);
  if (!payload) return requireResync(current, "non_object_payload");

  const payloadKind = typeof payload.kind === "string" ? payload.kind : undefined;
  const envelopeKind = envelope.event && envelope.event !== "message"
    ? envelope.event
    : undefined;
  if (payloadKind && envelopeKind && payloadKind !== envelopeKind) {
    return requireResync(current, "event_kind_mismatch");
  }
  const kind = payloadKind ?? envelopeKind;
  if (!kind) return requireResync(current, "missing_event_kind");

  if (payload.scope !== "service") {
    return ignored(current, "different_scope");
  }

  if (kind === "snapshot") {
    return applySnapshot(current, envelope, payload);
  }
  if (kind === "unavailable") {
    if (payload.service !== current.service) {
      return requireResync(current, "unavailable_service_mismatch");
    }
    return requireResync(current, "upstream_unavailable");
  }
  if (CHANGE_KINDS.has(kind)) {
    return applyHint(current, envelope, payload);
  }
  return requireResync(current, "unknown_event_kind");
}

function applySnapshot(
  current: ServiceDiscoveryReplica,
  envelope: ServiceWatchEnvelope,
  payload: Record<string, unknown>,
): ServiceDiscoveryApplyResult {
  if (payload.service !== current.service) {
    return requireResync(current, "snapshot_service_mismatch");
  }
  if (payload.authoritative !== true) {
    return requireResync(current, "non_authoritative_snapshot");
  }
  const instances = parseInstances(payload.instances);
  if (!instances) return requireResync(current, "invalid_snapshot_instances");

  const triggerRevision = parseOptionalRevision(payload.trigger_revision);
  if (triggerRevision.invalid) {
    return requireResync(current, "invalid_snapshot_revision");
  }
  const eventRevision = parseOptionalRevision(envelope.id);
  if (eventRevision.invalid) {
    return requireResync(current, "invalid_sse_id");
  }
  if (
    triggerRevision.value !== undefined &&
    eventRevision.value !== undefined &&
    triggerRevision.value !== eventRevision.value
  ) {
    return requireResync(current, "snapshot_revision_mismatch");
  }

  const revision = triggerRevision.value ?? eventRevision.value;
  if (
    revision !== undefined &&
    current.lastObservedRevision !== undefined &&
    revision < current.lastObservedRevision
  ) {
    return ignored(current, "stale_snapshot");
  }

  const lastObservedRevision = maxDefined(current.lastObservedRevision, revision);
  const next: ServiceDiscoveryReplica = Object.freeze({
    service: current.service,
    instances,
    synchronized: true,
    needsResync: false,
    ...(lastObservedRevision === undefined ? {} : { lastObservedRevision }),
    // Snapshots without an SSE id (initial, lag recovery, or TTL reconciliation)
    // are still authoritative at read time. They cover every revision this
    // consumer had already observed, even though the stream does not invent a
    // synthetic durable cursor for them.
    ...(lastObservedRevision === undefined
      ? {}
      : { lastSnapshotRevision: lastObservedRevision }),
  });
  return Object.freeze({ kind: "snapshot", state: next });
}

function applyHint(
  current: ServiceDiscoveryReplica,
  envelope: ServiceWatchEnvelope,
  payload: Record<string, unknown>,
): ServiceDiscoveryApplyResult {
  if (payload.key !== current.service) return ignored(current, "different_service");

  const payloadRevision = parseOptionalRevision(payload.revision);
  const eventRevision = parseOptionalRevision(envelope.id);
  if (
    payloadRevision.invalid ||
    eventRevision.invalid ||
    (payloadRevision.value === undefined && eventRevision.value === undefined)
  ) {
    return requireResync(current, "invalid_change_revision");
  }
  if (
    payloadRevision.value !== undefined &&
    eventRevision.value !== undefined &&
    payloadRevision.value !== eventRevision.value
  ) {
    return requireResync(current, "change_revision_mismatch");
  }
  const revision = payloadRevision.value ?? eventRevision.value;
  if (revision === undefined) return requireResync(current, "missing_change_revision");

  if (
    (current.lastObservedRevision !== undefined && revision <= current.lastObservedRevision) ||
    (current.lastSnapshotRevision !== undefined && revision <= current.lastSnapshotRevision)
  ) {
    return ignored(current, "stale_or_duplicate_change");
  }

  // Revisions belong to the shared shard, so gaps may represent unrelated keys
  // or services. Do not falsely infer data loss from a non-contiguous number.
  // The server explicitly emits a lag-recovery snapshot when its bounded
  // broadcast reports skipped events.
  const next: ServiceDiscoveryReplica = Object.freeze({
    ...current,
    synchronized: false,
    needsResync: false,
    lastObservedRevision: revision,
  });
  return Object.freeze({ kind: "hint", state: next });
}

function parseInstances(value: unknown): readonly ServiceInstance[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const seen = new Set<string>();
  const instances: ServiceInstance[] = [];
  for (const candidate of value) {
    const record = asRecord(candidate);
    if (!record) return undefined;
    const instanceId = record.instance_id;
    const address = record.address;
    const leaseExpiresMs = record.lease_expires_ms;
    const metadata = asRecord(record.metadata);
    if (
      typeof instanceId !== "string" ||
      !instanceId ||
      seen.has(instanceId) ||
      typeof address !== "string" ||
      !address ||
      typeof leaseExpiresMs !== "number" ||
      !Number.isSafeInteger(leaseExpiresMs) ||
      leaseExpiresMs < 0 ||
      !metadata
    ) {
      return undefined;
    }
    const copiedMetadata: Record<string, string> = {};
    for (const [key, entry] of Object.entries(metadata)) {
      if (typeof entry !== "string") return undefined;
      copiedMetadata[key] = entry;
    }
    seen.add(instanceId);
    instances.push(Object.freeze({
      instance_id: instanceId,
      address,
      lease_expires_ms: leaseExpiresMs,
      metadata: Object.freeze(copiedMetadata),
    }));
  }
  instances.sort((left, right) => left.instance_id.localeCompare(right.instance_id));
  return Object.freeze(instances);
}

function parseOptionalRevision(value: unknown): {
  readonly value?: number;
  readonly invalid: boolean;
} {
  if (value === undefined || value === null || value === "") {
    return { invalid: false };
  }
  const parsed = typeof value === "number" ? value : Number(value);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) return { invalid: true };
  return { value: parsed, invalid: false };
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  return value as Record<string, unknown>;
}

function maxDefined(left: number | undefined, right: number | undefined): number | undefined {
  if (left === undefined) return right;
  if (right === undefined) return left;
  return Math.max(left, right);
}

function requireResync(
  current: ServiceDiscoveryReplica,
  reason: string,
): ServiceDiscoveryApplyResult {
  const state = Object.freeze({
    ...current,
    synchronized: false,
    needsResync: true,
  });
  return Object.freeze({ kind: "resync_required", state, reason });
}

function ignored(
  state: ServiceDiscoveryReplica,
  reason: string,
): ServiceDiscoveryApplyResult {
  return Object.freeze({ kind: "ignored", state, reason });
}
