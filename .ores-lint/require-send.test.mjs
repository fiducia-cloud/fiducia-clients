import assert from 'node:assert/strict';
import test from 'node:test';

import { analyzeSource, formatReport } from './require-send.mjs';

test('Rust chains must terminate in send', () => {
  assert.equal(analyzeSource('fn emit() { logger.info("ready"); }', 'rust').length, 1);
  assert.deepEqual(analyzeSource('fn emit() { logger.info("ready").send(); }', 'rust'), []);
});

test('assigned events are tracked until delivery', () => {
  assert.equal(
    analyzeSource('fn emit() { let event = logger.warn("queued"); consume(); }', 'rust').length,
    1,
  );
  assert.deepEqual(
    analyzeSource('fn emit() { let event = logger.warn("queued"); event.send(); }', 'rust'),
    [],
  );
});

test('Dart chains share the delivery contract', () => {
  assert.equal(analyzeSource('void emit() { telemetry.error("failed"); }', 'dart').length, 1);
  assert.deepEqual(
    analyzeSource('void emit() { telemetry.error("failed").send_with_store(store); }', 'dart'),
    [],
  );
});

test('Gleam pipes require a terminal delivery step', () => {
  assert.equal(analyzeSource('fn emit() { logging.info("ready")\n  Nil }', 'gleam').length, 1);
  assert.deepEqual(
    analyzeSource('fn emit() { logging.info("ready") |> logging.send\n  Nil }', 'gleam'),
    [],
  );
});

test('documented suppressions are honored', () => {
  assert.deepEqual(
    analyzeSource(
      '// ores-lint-disable-next-line require-send\nfn emit() { logger.info("intentional"); }',
      'rust',
    ),
    [],
  );
  assert.deepEqual(
    analyzeSource(
      '// ores-lint-disable-file require-send\nfn emit() { logger.info("intentional"); }',
      'rust',
    ),
    [],
  );
});

test('convenience emit calls are already terminal', () => {
  assert.deepEqual(analyzeSource('fn emit() { logger.log(level, message, context); }', 'rust'), []);
});

test('reports retain file and source location', () => {
  const report = formatReport([
    {
      file: 'src/lib.rs',
      findings: analyzeSource('fn emit() { logger.info("ready"); }', 'rust'),
    },
  ]);
  assert.match(report, /1 finding\(s\)/);
  assert.match(report, /src\/lib\.rs:1:/);
});
