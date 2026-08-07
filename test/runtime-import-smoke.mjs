import assert from "node:assert/strict";

const runtime = globalThis.Deno ? "deno" : globalThis.Bun ? "bun" : "node";
const candidates = runtime === "node"
  ? ["../dist/index.js", "../dist/index.mjs", "../lib/index.js"]
  : ["../src/index.ts", "../src/index.js", "../dist/index.js", "../dist/index.mjs"];

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
