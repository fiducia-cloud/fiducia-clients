// Import the real published TypeScript source entrypoint. The repository has no
// root src/index module; clients/ts/fiducia.ts is also what Node, Deno, and Bun
// exercise in runtime-import-smoke.mjs.
import * as sdk from "../clients/ts/fiducia.ts";

export default {
  async fetch(): Promise<Response> {
    const exports = Object.keys(sdk);
    return Response.json(
      {ok: exports.length > 0, exports},
      {status: exports.length > 0 ? 200 : 500},
    );
  },
};
