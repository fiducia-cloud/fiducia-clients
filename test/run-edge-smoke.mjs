import assert from "node:assert/strict";
import {spawn} from "node:child_process";

const port = 8791;
const child = spawn(
  process.platform === "win32" ? "npx.cmd" : "npx",
  ["wrangler", "dev", "--config", "test/wrangler.toml", "--port", String(port), "--log-level", "error"],
  {cwd: new URL("..", import.meta.url), stdio: ["ignore", "pipe", "pipe"]},
);
let logs = "";
child.stdout.on("data", (chunk) => { logs += chunk; });
child.stderr.on("data", (chunk) => { logs += chunk; });

try {
  let response;
  for (let attempt = 0; attempt < 80; attempt += 1) {
    try {
      response = await fetch(`http://127.0.0.1:${port}/`);
      if (response.ok) break;
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  assert.ok(response, `Wrangler did not start\n${logs}`);
  assert.equal(response.status, 200, logs);
  const result = await response.json();
  assert.equal(result.ok, true, logs);
  assert.ok(Array.isArray(result.exports) && result.exports.length > 0, logs);
  console.log(`edge client import smoke passed with ${result.exports.length} exports`);
} finally {
  child.kill("SIGTERM");
  await Promise.race([
    new Promise((resolve) => child.once("exit", resolve)),
    new Promise((resolve) => setTimeout(resolve, 3000)),
  ]);
  if (child.exitCode === null) child.kill("SIGKILL");
}
