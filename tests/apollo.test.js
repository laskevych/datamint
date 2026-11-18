const test = require('node:test');
const assert = require('node:assert');

process.env.APOLLO_API_KEY = process.env.APOLLO_API_KEY || 'test-key';
process.env.BATCH_SIZE = '10';

const { bulkEnrichOrganizations } = require('../src/index');

test('bulkEnrichOrganizations rejects more than BATCH_SIZE domains', async () => {
  const oversized = Array.from({ length: 11 }, (_, i) => `d${i}.com`);
  await assert.rejects(
    () => bulkEnrichOrganizations(oversized),
    /can be enriched at the same time/
  );
});
