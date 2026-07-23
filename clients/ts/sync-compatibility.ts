import type { PullPage, SendWrite } from "@fiducia/sync";

import { FiduciaClient } from "./fiducia.ts";

declare const client: FiduciaClient;

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
