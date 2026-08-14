import assert from "node:assert/strict";
import {spawn} from "node:child_process";
import {fileURLToPath} from "node:url";

const port = 8791;
const isWindows = process.platform === "win32";
const repoRoot = fileURLToPath(new URL("..", import.meta.url));
const wranglerArgs = [
  "dev",
  "--config",
  "test/wrangler.toml",
  "--port",
  String(port),
  "--log-level",
  "error",
];
const child = spawn(
  isWindows
    ? "npx.cmd"
    : fileURLToPath(new URL("../clients/ts/node_modules/.bin/wrangler", import.meta.url)),
  isWindows ? ["wrangler", ...wranglerArgs] : wranglerArgs,
  {
    cwd: repoRoot,
    detached: !isWindows,
    stdio: ["ignore", "pipe", "pipe"],
  },
);
let logs = "";
child.stdout.on("data", (chunk) => { logs += chunk; });
child.stderr.on("data", (chunk) => { logs += chunk; });

const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
const waitForExit = () => (
  child.exitCode === null
    ? new Promise((resolve) => child.once("exit", resolve))
    : Promise.resolve()
);
const terminate = (signal) => {
  if (child.exitCode !== null) return;
  if (!isWindows && child.pid) {
    try {
      process.kill(-child.pid, signal);
      return;
    } catch {
      // Fall back to terminating only the direct child.
    }
  }
  child.kill(signal);
};

try {
  let response;
  for (let attempt = 0; attempt < 80; attempt += 1) {
    try {
      response = await fetch(`http://127.0.0.1:${port}/`);
      if (response.ok) break;
    } catch {}
    await delay(250);
  }
  assert.ok(response, `Wrangler did not start\n${logs}`);
  assert.equal(response.status, 200, logs);
  const result = await response.json();
  assert.equal(result.ok, true, logs);
  assert.ok(Array.isArray(result.exports) && result.exports.length > 0, logs);
  console.log(`edge client import smoke passed with ${result.exports.length} exports`);
} finally {
  terminate("SIGTERM");
  await Promise.race([waitForExit(), delay(3000)]);
  if (child.exitCode === null) {
    terminate("SIGKILL");
    await Promise.race([waitForExit(), delay(1000)]);
  }
  child.stdout.destroy();
  child.stderr.destroy();
}
