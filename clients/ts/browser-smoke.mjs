// Browser-level contract tests for the TypeScript Fiducia client.
//
// This intentionally uses only Node's standard library. The repository's
// locked TypeScript CLI emits .browser-dist/fiducia.js before this runner starts.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import process from "node:process";
import { runBrowserContract } from "./chrome-cdp.mjs";

const chromePath = process.env.CHROME_PATH;
assert.ok(chromePath, "CHROME_PATH must point to a Chrome/Chromium executable");

const browserModule = await readFile(
  new URL("./.browser-dist/fiducia.js", import.meta.url),
  "utf8",
);
assert.ok(
  browserModule.includes("export class FiduciaClient"),
  "locked tsc output does not expose FiduciaClient as a browser ES module",
);

const calls = [];
let redirectTargetHits = 0;
let retryFailures = 0;
const maxBodyBytes = 64 * 1024;

function send(res, status, body, headers = {}) {
  const payload = typeof body === "string" ? body : JSON.stringify(body);
  res.writeHead(status, {
    "cache-control": "no-store",
    "content-length": Buffer.byteLength(payload),
    "x-content-type-options": "nosniff",
    ...headers,
  });
  res.end(payload);
}

function sendJson(res, status, body, headers = {}) {
  send(res, status, body, { "content-type": "application/json; charset=utf-8", ...headers });
}

async function readJson(req) {
  const chunks = [];
  let total = 0;
  for await (const chunk of req) {
    total += chunk.length;
    if (total > maxBodyBytes) throw new Error("browser test request body exceeded 64 KiB");
    chunks.push(chunk);
  }
  if (chunks.length === 0) return undefined;
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

function record(req, url, body) {
  calls.push({
    method: req.method ?? "GET",
    path: `${url.pathname}${url.search}`,
    body,
    idempotencyKey: req.headers["idempotency-key"],
  });
}

const browserTestModule = String.raw`
import { FiduciaClient, FiduciaError, FiduciaTimeoutError } from "/fiducia.js";

const output = document.querySelector("#output");
const passed = [];
const check = (condition, message) => {
  if (!condition) throw new Error(message);
};
const mark = (name) => passed.push(name);

try {
  const client = new FiduciaClient(location.origin, { maxRetries: 1, retryDelayMs: 0 });

  const lock = await client.lockGet("orders/42");
  check(lock?.key === "orders/42", "slash-safe lock routing failed in Chrome");
  mark("routing");

  let redirectFailure;
  try {
    await client.lockGet("redirect");
  } catch (error) {
    redirectFailure = error;
  }
  check(redirectFailure instanceof FiduciaError, "redirect must throw FiduciaError");
  check(redirectFailure?.body?.error === "redirect_not_followed", "redirect error code missing");
  mark("redirect-hard-reject");

  let timeoutFailure;
  try {
    await client.tryLock("slow", { holder: "browser-timeout", timeoutMs: 30 });
  } catch (error) {
    timeoutFailure = error;
  }
  check(timeoutFailure instanceof FiduciaTimeoutError, "AbortController timeout did not surface");
  check(timeoutFailure.timeoutMs === 30, "timeout metadata changed");
  mark("timeout");

  await client.tryLock("retry", {
    holder: "browser-retry",
    idempotencyKey: "browser-idempotency-1",
    maxRetries: 1,
  });
  mark("retry");

  const generatedOne = await client.tryLock("random-one");
  const generatedTwo = await client.tryLock("random-two");
  check(/^fdc-[0-9a-f-]{32,36}$/.test(generatedOne.holder), "browser Web Crypto holder is invalid");
  check(generatedOne.holder !== generatedTwo.holder, "browser-generated holders must be unique");
  mark("web-crypto");

  const events = [];
  for await (const event of client.kvWatch("watch", { timeoutMs: 1_000 })) {
    events.push(event);
    if (events.length === 2) break;
  }
  check(events[0]?.event === "put" && events[0]?.id === "1", "first SSE event was not decoded");
  check(events[1]?.event === "delete" && events[1]?.id === "2", "second SSE event was not decoded");
  check(events[0]?.data?.value === "one", "SSE JSON data was not parsed");
  mark("sse-stream");

  const state = await fetch("/__state", { cache: "no-store" }).then((response) => response.json());
  const retryCalls = state.calls.filter((call) => call.body?.key === "retry");
  check(retryCalls.length === 2, "marked not-leader mutation was not retried exactly once");
  check(
    retryCalls.every((call) => call.idempotencyKey === "browser-idempotency-1"),
    "caller idempotency key changed between browser retry attempts",
  );
  check(state.redirectTargetHits === 0, "Chrome followed a redirect that the client must reject");
  check(
    state.calls.filter((call) => call.path.includes("key=redirect")).length === 1,
    "redirect response was incorrectly retried",
  );
  mark("server-observations");

  document.body.dataset.status = "passed";
  output.textContent = JSON.stringify({ passed }, null, 2);
} catch (error) {
  document.body.dataset.status = "failed";
  output.textContent = JSON.stringify({
    name: error?.name ?? "Error",
    message: error?.message ?? String(error),
    stack: error?.stack,
  }, null, 2);
}
`;

const html = `<!doctype html>
<html lang="en">
  <head><meta charset="utf-8"><title>Fiducia browser contract</title></head>
  <body data-status="running">
    <pre id="output">running</pre>
    <script type="module" src="/browser-tests.js"></script>
  </body>
</html>`;

const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url ?? "/", "http://127.0.0.1");
    if (url.pathname === "/") {
      send(res, 200, html, {
        "content-type": "text/html; charset=utf-8",
        "content-security-policy": "default-src 'none'; script-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
      });
      return;
    }
    if (url.pathname === "/fiducia.js") {
      send(res, 200, browserModule, {
        "content-type": "text/javascript; charset=utf-8",
        "cross-origin-resource-policy": "same-origin",
      });
      return;
    }
    if (url.pathname === "/browser-tests.js") {
      send(res, 200, browserTestModule, {
        "content-type": "text/javascript; charset=utf-8",
        "cross-origin-resource-policy": "same-origin",
      });
      return;
    }
    if (url.pathname === "/__state") {
      sendJson(res, 200, { calls, redirectTargetHits });
      return;
    }
    if (url.pathname === "/redirect-target") {
      redirectTargetHits += 1;
      sendJson(res, 200, { leaked: true });
      return;
    }
    if (url.pathname === "/v1/locks" && req.method === "GET") {
      record(req, url, undefined);
      const key = url.searchParams.get("key");
      if (key === "redirect") {
        res.writeHead(307, {
          "cache-control": "no-store",
          location: "/redirect-target",
          "x-content-type-options": "nosniff",
        });
        res.end();
        return;
      }
      sendJson(res, 200, { key });
      return;
    }
    if (url.pathname === "/v1/locks/acquire" && req.method === "POST") {
      const body = await readJson(req);
      record(req, url, body);
      if (body?.key === "slow") {
        setTimeout(() => {
          if (!res.destroyed) sendJson(res, 200, { key: body.key, holder: body.holder });
        }, 200);
        return;
      }
      if (body?.key === "retry" && retryFailures++ === 0) {
        sendJson(res, 503, { error: "not_leader", retryable: true }, {
          "x-fiducia-not-leader": "true",
        });
        return;
      }
      sendJson(res, 200, { key: body?.key, holder: body?.holder });
      return;
    }
    if (
      url.pathname === "/v1/kv"
      && req.method === "GET"
      && url.searchParams.get("watch") === "true"
    ) {
      record(req, url, undefined);
      res.writeHead(200, {
        "cache-control": "no-store",
        connection: "keep-alive",
        "content-type": "text/event-stream; charset=utf-8",
        "x-content-type-options": "nosniff",
      });
      res.write('id: 1\nevent: put\ndata: {"key":"watch","value":"one"}\n\n');
      setTimeout(() => {
        if (!res.destroyed) {
          res.end('id: 2\nevent: delete\ndata: {"key":"watch"}\n\n');
        }
      }, 20);
      return;
    }
    sendJson(res, 404, { error: "not_found" });
  } catch (error) {
    if (!res.headersSent) sendJson(res, 500, { error: "test_server_error" });
    else res.destroy();
    console.error(error);
  }
});
server.on("clientError", (_error, socket) => socket.destroy());

await new Promise((resolve, reject) => {
  server.once("error", reject);
  server.listen(0, "127.0.0.1", resolve);
});
const address = server.address();
assert.ok(address && typeof address === "object", "browser test server did not bind");
const pageUrl = `http://127.0.0.1:${address.port}/`;
const profile = await mkdtemp(path.join(tmpdir(), "fiducia-chrome-"));

try {
  await runBrowserContract({ chromePath, pageUrl, profile });
  console.log("Fiducia TypeScript browser contract passed in real Chrome");
} finally {
  await new Promise((resolve) => server.close(resolve));
  await rm(profile, { recursive: true, force: true });
}
