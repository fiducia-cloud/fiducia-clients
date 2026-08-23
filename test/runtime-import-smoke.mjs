import assert from "node:assert/strict";

const runtime = globalThis.Deno ? "deno" : globalThis.Bun ? "bun" : "node";
// The TypeScript client lives in clients/ts (Tier 1 in clients/SUPPORT_TIERS.md)
// and ships as source: no build step, no dist/, entry `fiducia.ts`. These paths
// previously resolved to a repo-root dist/ and lib/ that have never existed, so
// this smoke could not import the client in any runtime. Node needs
// --experimental-strip-types to load the .ts entry; Deno and Bun load it natively.
const candidates = [
  "../clients/ts/fiducia.ts",
  "../clients/ts/dist/index.js",
  "../clients/ts/dist/index.mjs",
];

let sdk;
let lastError;
for (const candidate of candidates) {
  try {
    sdk = await import(new URL(candidate, import.meta.url));
    break;
  } catch (error) {
    lastError = error;
  }
}

assert.ok(sdk, `could not import the TypeScript client in ${runtime}: ${lastError}`);
assert.ok(Object.keys(sdk).length > 0, "client module must export a public API");
assert.equal(typeof fetch, "function", `${runtime} must expose fetch`);
assert.equal(typeof Headers, "function", `${runtime} must expose Headers`);
assert.equal(typeof Request, "function", `${runtime} must expose Request`);
assert.equal(typeof Response, "function", `${runtime} must expose Response`);
console.log(`${runtime} client import smoke passed with ${Object.keys(sdk).length} exports`);
