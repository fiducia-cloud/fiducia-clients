import assert from 'node:assert/strict';
import test from 'node:test';

import oresConfig from './eslint/base.mjs';
import oresPlugin from './eslint/plugin.mjs';
import oresFormatter from './eslint/formatter.mjs';

test('vendored plugin exports the required house rules', () => {
  assert.equal(oresPlugin.meta.name, 'ores-lint');
  assert.equal(typeof oresPlugin.rules['require-send'].create, 'function');
  assert.equal(typeof oresPlugin.rules.semi.create, 'function');
});

test('flat-config factory remains usable without optional TypeScript tooling', async () => {
  const config = await oresConfig();
  assert.ok(Array.isArray(config));
  assert.ok(config.some((entry) => entry.plugins?.ores === oresPlugin));
  assert.ok(config.some((entry) => entry.rules?.['ores/require-send']));
});

test('formatter distinguishes clean coverage from an empty match set', () => {
  assert.match(oresFormatter([]), /no lintable files matched/);
  assert.match(
    oresFormatter([{ filePath: '/tmp/example.mjs', messages: [] }]),
    /clean \(1 file linted\)/,
  );
});
