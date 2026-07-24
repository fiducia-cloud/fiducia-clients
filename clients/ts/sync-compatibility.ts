import type {
  PullPage,
  SendWrite,
  SyncClient,
  SyncWritePolicy as RuntimeSyncWritePolicy,
} from "@fiducia/sync";
import type {
  SyncWritePolicy as InterfaceSyncWritePolicy,
} from "@fiducia/interfaces/typescript";

import { FiduciaClient } from "./fiducia.ts";

declare const client: FiduciaClient;
declare const syncClient: SyncClient;

// Compile-time proof that fiducia-clients can be passed directly to the two
// transport callbacks consumed by @fiducia/sync startSync()/optimisticWrite().
export const sendWrite: SendWrite = client.syncSender({
  pathPrefix: "/api/admin/sync",
});

export const pullFetch = (table: string): ((cursor: number, limit: number) => Promise<PullPage>) =>
  (cursor, limit) => client.syncPull(table, cursor, {
    pathPrefix: "/api/admin/sync",
    limit,
  });

// The canonical interface policy and the runtime SDK policy remain structurally
// identical, and the HTTP sender accepts the SDK's replica-only queue metadata
// while stripping it from the server wire envelope.
export const mobileWritePolicy: InterfaceSyncWritePolicy = {
  strategy: "local_queue",
  failure_mode: "emit_only",
  telemetry: "lifecycle",
};
export const runtimeWritePolicy: RuntimeSyncWritePolicy = mobileWritePolicy;

export const policyDrivenWrite = syncClient.write(
  "infra_operations",
  "operation-7",
  { state: "queued" },
  sendWrite,
  { policy: runtimeWritePolicy },
);
