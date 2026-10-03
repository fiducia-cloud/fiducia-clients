import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(fileURLToPath(new URL("..", import.meta.url)));
const clientsRoot = path.join(root, "clients");
const inventory = JSON.parse(
  await readFile(path.join(clientsRoot, "support-tiers.json"), "utf8"),
);

function sorted(values) {
  return [...values].sort((left, right) => left.localeCompare(right));
}

function assertUnique(label, values) {
  assert.equal(new Set(values).size, values.length, `${label} contains duplicates`);
}

function assertSame(label, actual, expected) {
  assert.deepEqual(
    sorted(actual),
    sorted(expected),
    `${label} drifted\nactual: ${sorted(actual).join(", ")}\nexpected: ${sorted(expected).join(", ")}`,
  );
}

assert.equal(inventory.schema_version, 1, "unsupported support-tier schema version");
assert.deepEqual(Object.keys(inventory.tiers).sort(), ["1", "2", "3", "4"]);

const tierClients = [];
for (const [tier, definition] of Object.entries(inventory.tiers)) {
  assert.equal(typeof definition.name, "string", `tier ${tier} is missing a name`);
  assert.ok(Array.isArray(definition.clients), `tier ${tier} clients must be an array`);
  assert.ok(definition.clients.length > 0, `tier ${tier} must not be empty`);
  assertUnique(`tier ${tier}`, definition.clients);
  for (const client of definition.clients) {
    assert.match(client, /^[a-z][a-z0-9-]*$/, `invalid client directory name: ${client}`);
    tierClients.push(client);
  }
}
assertUnique("support tiers", tierClients);

const actualClientEntries = await readdir(clientsRoot, { withFileTypes: true });
const actualClients = actualClientEntries
  .filter((entry) => entry.isDirectory() && !entry.name.startsWith("."))
  .map((entry) => entry.name);
assertSame("clients/* directories versus support tiers", actualClients, tierClients);

const generated = inventory.maintenance.generated_from_operations;
const explicit = inventory.maintenance.explicit_hand_maintained_or_packaged;
assert.ok(Array.isArray(generated), "generated maintenance list must be an array");
assert.ok(Array.isArray(explicit), "explicit maintenance list must be an array");
assertUnique("generated maintenance list", generated);
assertUnique("explicit maintenance list", explicit);
for (const client of generated) {
  assert.ok(!explicit.includes(client), `${client} is both generated and hand-maintained`);
}
assertSame("maintenance classification", [...generated, ...explicit], actualClients);

const generator = await readFile(path.join(root, "generate.py"), "utf8");
const generatorClients = [];
const generatorTarget = /^\s*"[^"]+":\s*\("clients\/([^/"\n]+)\//gm;
for (const match of generator.matchAll(generatorTarget)) generatorClients.push(match[1]);
assertSame("generate.py client outputs versus generated maintenance list", generatorClients, generated);

const zpkg = await readFile(path.join(root, ".zpkg.toml"), "utf8");
const publishedClients = [];
const publishTarget = /^dir\s*=\s*"clients\/([^/"\n]+)"\s*$/gm;
for (const match of zpkg.matchAll(publishTarget)) publishedClients.push(match[1]);
assertUnique(".zpkg.toml client targets", publishedClients);
assertSame(".zpkg.toml targets versus support tiers", publishedClients, actualClients);

const supportDoc = await readFile(path.join(clientsRoot, "SUPPORT_TIERS.md"), "utf8");
const documentedClients = new Set();
for (const match of supportDoc.matchAll(/`clients\/([a-z][a-z0-9-]*)`/g)) {
  documentedClients.add(match[1]);
}
for (const client of actualClients) {
  assert.ok(documentedClients.has(client), `SUPPORT_TIERS.md does not mention clients/${client}`);
}
for (const client of documentedClients) {
  assert.ok(actualClients.includes(client), `SUPPORT_TIERS.md references a missing client: clients/${client}`);
}
assert.match(
  supportDoc,
  /support-tiers\.json/,
  "SUPPORT_TIERS.md must identify the machine-readable inventory",
);

console.log(
  `support inventory verified: ${actualClients.length} clients, `
    + `${generated.length} generated, ${explicit.length} explicit`,
);
