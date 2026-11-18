const test = require('node:test');
const assert = require('node:assert');
const { chunk, sleep, buildEnrichmentRecords } = require('../src/index');

test('chunk splits array into equal batches', () => {
  assert.deepStrictEqual(chunk([1, 2, 3, 4], 2), [[1, 2], [3, 4]]);
});

test('chunk handles remainder', () => {
  assert.deepStrictEqual(chunk([1, 2, 3, 4, 5], 2), [[1, 2], [3, 4], [5]]);
});

test('chunk returns empty array for empty input', () => {
  assert.deepStrictEqual(chunk([], 3), []);
});

test('chunk wraps everything in one batch when size exceeds length', () => {
  assert.deepStrictEqual(chunk([1, 2], 10), [[1, 2]]);
});

test('chunk throws on non-array input', () => {
  assert.throws(() => chunk('abc', 2), TypeError);
});

test('chunk throws on non-positive size', () => {
  assert.throws(() => chunk([1, 2], 0), RangeError);
  assert.throws(() => chunk([1, 2], -1), RangeError);
});

test('sleep resolves after the given delay', async () => {
  const start = Date.now();
  await sleep(30);
  const elapsed = Date.now() - start;
  assert.ok(elapsed >= 25, `expected >=25ms, got ${elapsed}ms`);
});

test('buildEnrichmentRecords pairs domains with organizations and stringifies data', () => {
  const now = new Date('2026-01-01T00:00:00.000Z');
  const records = buildEnrichmentRecords(
    ['a.com', 'b.com'],
    [{ industry: 'software' }, null],
    now
  );

  assert.strictEqual(records.length, 2);
  assert.strictEqual(records[0].domain, 'a.com');
  assert.strictEqual(records[0].data, '{"industry":"software"}');
  assert.strictEqual(records[0].createdAt, '2026-01-01T00:00:00.000Z');
  assert.strictEqual(records[1].domain, 'b.com');
  assert.strictEqual(records[1].data, null);
});
