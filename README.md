# Datamint

An ELT pipeline on Google Cloud that enriches B2B leads with firmographic data from [Apollo.io](https://www.apollo.io/) and classifies them in BigQuery — with plain SQL rules and K-Medoids clustering.

Sales gets one table, `leads`, where every company has an industry, a size bucket, a country, a qualification label (`sqlSize`) and a segment (`cluster_id`).

## Architecture

```
Cloud Scheduler ──▶ Cloud Function (Node.js 18+) ──▶ Apollo API (organizations/bulk_enrich)
                          │
                          ├──▶ BigQuery: leads_to_enrich (VIEW)    read: domains without data
                          ├──▶ BigQuery: enrichment_data_raw       write: raw JSON responses
                          └──▶ Google Chat webhook                 on error

BigQuery scheduled queries:
  1. sql/02-transform.sql   raw JSON → enrichment_data_transformed
                            (canonical industry / country, company-size bucket)
  2. sql/03_score.sql       → leads.sqlSize   (rule-based CASE)
  3. sql/04_clustering.sql  → cluster_medoids + leads.cluster_id
                            (K-Medoids with Gower distance in a JS UDF)
```

## How it works

**Extract & load** (`src/index.js`). The function reads up to `FETCH_LIMIT` domains from the `leads_to_enrich` view, sends them to Apollo in batches of `BATCH_SIZE` (Apollo's bulk-enrich limit), sleeps `SLEEP_MS` between batches to respect rate limits, and inserts each raw response into `enrichment_data_raw` as JSON. Any error is posted to a Google Chat webhook. The Apollo key comes from Secret Manager.

**Transform** (`sql/02-transform.sql`). Raw industry and country values are mapped to canonical titles through inline dictionaries — no lookup tables to keep in sync. Employee counts become ordered size buckets (`'1. 0-1'` … `'9. 10,001+'`). The latest record per domain wins.

**Classify** (`sql/03_score.sql`). A white-box `CASE` turns three signals — country, industry and size — into `Yes / Probably Yes / No / Unknown`. To change the rules, an analyst edits the SQL and re-saves the scheduled query; there is no model to retrain.

**Segment** (`sql/04_clustering.sql`). K-Medoids (a simplified PAM) groups companies into `k = 4` segments. Gower distance handles mixed data: categorical features count as 0/1 mismatches, size is a normalized numeric gap, and NULL features are skipped. Medoids are always real companies with a complete profile, so every segment has a concrete, explainable representative.

## Project structure

```
src/index.js            Cloud Function: BigQuery → Apollo → BigQuery, Chat alerts
sql/01_schema.sql       tables and the leads_to_enrich view
sql/02-transform.sql    raw → canonical enrichment data
sql/03_score.sql        rule-based qualification (sqlSize)
sql/04_clustering.sql   Gower UDF + K-Medoids script
tests/                  unit tests (node:test)
```

## Setup

1. Create a BigQuery dataset `datamint`, replace `@project` with your project id in `sql/01_schema.sql` and run it.
2. Store your Apollo API key in Secret Manager as `apollo-api-key`.
3. Create a service account with `BigQuery Data Editor`, `BigQuery Job User`, `Secret Manager Secret Accessor` and `Logs Writer`.
4. Deploy `src/index.js` with `package.json` as a 2nd gen HTTP Cloud Function (entry point `app`, Node.js 18+). Set the variables from `.env.example` and map `APOLLO_API_KEY` to the secret.
5. Add a Cloud Scheduler job that calls the function, and save `02`, `03` and `04` as BigQuery scheduled queries in that order.

Run locally:

```bash
npm install
cp .env.example .env   # fill in the values
IS_DEV_ENV=1 node src/index.js
```

## Tests

```bash
npm test
```

## License

MIT
