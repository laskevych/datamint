const cloudFunctions = require('@google-cloud/functions-framework');
const axios = require('axios');
const { BigQuery } = require('@google-cloud/bigquery');

// ----- config (env-vars) -----
const PROJECT_ID = process.env.GCP_PROJECT_ID;
const DATASET = process.env.BQ_DATASET || 'datamint';
const LOCATION = process.env.BQ_LOCATION || 'US';

const FETCH_LIMIT = parseInt(process.env.FETCH_LIMIT, 10) || 50;
const BATCH_SIZE = parseInt(process.env.BATCH_SIZE, 10) || 10;
const SLEEP_MS = parseInt(process.env.SLEEP_MS, 10) || 5000;

const TABLES = {
  leadsToEnrichView: `${PROJECT_ID}.${DATASET}.leads_to_enrich`,
  enrichmentRaw: { dataset: DATASET, table: 'enrichment_data_raw' },
};

// ----- shared clients -----
const bigquery = new BigQuery({ projectId: PROJECT_ID });
const apolloClient = axios.create({
  baseURL: 'https://api.apollo.io/api/v1',
  headers: {
    'Content-Type': 'application/json',
    'X-Api-Key': process.env.APOLLO_API_KEY,
  },
});

// ----- utils -----
function chunk(arr, size) {
  if (!Array.isArray(arr)) throw new TypeError('chunk: first argument must be an array');
  if (!Number.isInteger(size) || size <= 0) throw new RangeError('chunk: size must be a positive integer');

  const result = [];
  for (let i = 0; i < arr.length; i += size) {
    result.push(arr.slice(i, i + size));
  }
  return result;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function buildEnrichmentRecords(batch, organizations, now = new Date()) {
  return batch.map((domain, idx) => {
    const enriched = organizations[idx];
    return {
      domain,
      data: enriched ? JSON.stringify(enriched) : null,
      createdAt: now.toISOString(),
    };
  });
}

// ----- Apollo client -----
async function bulkEnrichOrganizations(domains) {
  if (domains.length > BATCH_SIZE) {
    throw new Error(`Up to ${BATCH_SIZE} records can be enriched at the same time.`);
  }

  try {
    const response = await apolloClient.post('/organizations/bulk_enrich/', { domains });

    if (response.data && response.data.status && response.data.status !== 'success') {
      throw new Error(
        `Apollo API error! Message: ${response.data.error_message}. Code: ${response.data.error_code}.`
      );
    }

    if (!response.data || !Array.isArray(response.data.organizations)) {
      throw new Error('Apollo API did not return an array of organizations.');
    }

    return response.data.organizations;
  } catch (error) {
    if (error.response) {
      throw new Error(
        `Apollo API request failed with status ${error.response.status}: ${error.response.statusText}`
      );
    }
    throw new Error(`Apollo API request failed: ${error.message}`);
  }
}

// ----- BigQuery I/O -----
async function getDomainsToEnrich() {
  const query = `SELECT domain FROM \`${TABLES.leadsToEnrichView}\` LIMIT ${FETCH_LIMIT}`;

  try {
    const [job] = await bigquery.createQueryJob({ query, location: LOCATION });
    const [rows] = await job.getQueryResults();

    const domains = rows.map((row) => row.domain).filter(Boolean);
    console.log(`Fetched ${domains.length} domains from \`${TABLES.leadsToEnrichView}\``);

    return domains;
  } catch (error) {
    const details = error.message || error.errors?.[0]?.errors?.[0]?.message || 'unknown error';
    throw new Error(`Error selecting from BigQuery. Details: ${details}`);
  }
}

async function insertEnrichmentRaw(records) {
  if (!records || records.length === 0) return;

  try {
    await bigquery
      .dataset(TABLES.enrichmentRaw.dataset)
      .table(TABLES.enrichmentRaw.table)
      .insert(records);
  } catch (error) {
    const details =
      error.message ||
      error.errors?.[0]?.errors?.[0]?.message ||
      JSON.stringify(error.errors || error);
    throw new Error(`Error inserting into BigQuery. Details: ${details}`);
  }
}

// ----- Google Chat notification -----
async function sendChatNotification(message) {
  const webhookUrl = process.env.CHAT_WEBHOOK_URL;
  if (!webhookUrl) {
    console.warn('CHAT_WEBHOOK_URL is not set, skipping chat notification.');
    return;
  }

  const text = `*Datamint Error:* ${message}`;

  try {
    await axios.post(webhookUrl, { text }, {
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
    });
  } catch (error) {
    console.error('Failed to send chat notification:', error.message);
  }
}

// ----- orchestration -----
async function enrichOrganizations() {
  const domains = await getDomainsToEnrich();

  if (!domains || domains.length === 0) {
    console.log('No domains to enrich!');
    return;
  }

  const batches = chunk(domains, BATCH_SIZE);
  console.log(`Split ${domains.length} domains into ${batches.length} batch(es) of up to ${BATCH_SIZE}.`);

  for (let i = 0; i < batches.length; i++) {
    const batch = batches[i];
    console.time(`batch_${i}`);
    console.log(`\nBatch ${i + 1}/${batches.length}: ${batch.join(', ')}`);

    const organizations = await bulkEnrichOrganizations(batch);
    const records = buildEnrichmentRecords(batch, organizations);

    await insertEnrichmentRaw(records);

    const enrichedCount = records.filter((r) => r.data !== null).length;
    console.log(`Inserted ${records.length} rows (${enrichedCount} with Apollo data).`);
    console.timeEnd(`batch_${i}`);

    if (i < batches.length - 1) {
      console.log(`Sleeping ${SLEEP_MS / 1000}s to respect Apollo rate limits...`);
      await sleep(SLEEP_MS);
    }
  }
}

async function run() {
  console.time('functionExecutionTime');
  try {
    await enrichOrganizations();
  } catch (error) {
    console.error(error);
    await sendChatNotification(error.message);
    throw error;
  } finally {
    console.timeEnd('functionExecutionTime');
  }
}

// ----- HTTP entry point -----
cloudFunctions.http('app', async (req, res) => {
  try {
    await run();
    res.status(200).send('ok');
  } catch (error) {
    res.status(500).send(error.message);
  }
});

if (process.env.IS_DEV_ENV) {
  (async () => {
    await run();
  })();
}

module.exports = {
  run,
  chunk,
  sleep,
  buildEnrichmentRecords,
  bulkEnrichOrganizations,
  getDomainsToEnrich,
  insertEnrichmentRaw,
  sendChatNotification,
};
