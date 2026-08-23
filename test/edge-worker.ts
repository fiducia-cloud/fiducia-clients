import * as sdk from "../src/index";

export default {
  async fetch(): Promise<Response> {
    const exports = Object.keys(sdk);
    return Response.json(
      {ok: exports.length > 0, exports},
      {status: exports.length > 0 ? 200 : 500},
    );
  },
};
