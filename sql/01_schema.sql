-- Datamint schema. Replace @project with your GCP project id before running.
-- Dataset assumed: datamint
-- Uses CREATE TABLE IF NOT EXISTS, so re-running it never alters existing tables.

-- Final business-ready table (sales manager reads this).
-- sqlSize is computed directly by a rule-based CASE in sql/03_score.sql
-- (no numeric score column — white-box classification on canonical signals).
CREATE TABLE IF NOT EXISTS `@project.datamint.leads` (
  domain STRING NOT NULL,
  industry STRING,
  size STRING,             -- prefixed bucket: '1. 0-1' / '2. 2-10' / ... / '9. 10,001+'
  country STRING,
  sqlSize STRING,          -- 'Yes' / 'Probably Yes' / 'No' / 'Unknown'
  cluster_id INT64,        -- K-Medoids cluster assignment (sql/04_clustering.sql)
  createdAt TIMESTAMP NOT NULL
)
PARTITION BY DATE(createdAt);

-- Medoid (representative object) for each cluster, kept for interpretability.
CREATE TABLE IF NOT EXISTS `@project.datamint.cluster_medoids` (
  cluster_id INT64 NOT NULL,
  domain STRING NOT NULL,
  industry STRING,
  country STRING,
  size FLOAT64
);

-- Raw API responses (schema-on-read).
CREATE TABLE IF NOT EXISTS `@project.datamint.enrichment_data_raw` (
  domain STRING NOT NULL,
  data JSON,
  createdAt TIMESTAMP NOT NULL
)
PARTITION BY DATE(createdAt);

-- Cleaned + canonicalized enrichment data (output of sql/02-transform.sql).
-- industry/country are normalized to canonical titles via inline dictionaries
-- in the transform step (no lookup tables). size is a bucket string.
-- country_flag mirrors the dictionary's 'Yes' / 'No' label (excluded countries
-- are already mapped to 'No' in the dictionary). industry_is_sql_size mirrors
-- the dictionary's TRUE/FALSE flag.
CREATE TABLE IF NOT EXISTS `@project.datamint.enrichment_data_transformed` (
  domain STRING NOT NULL,
  industry STRING,
  size STRING,
  country STRING,
  country_flag STRING,        -- 'Yes' / 'No' / NULL (unknown raw country)
  industry_is_sql_size BOOL,
  createdAt TIMESTAMP NOT NULL
)
PARTITION BY DATE(createdAt);

-- Source view for the Cloud Function: leads that are not enriched yet.
CREATE OR REPLACE VIEW `@project.datamint.leads_to_enrich` AS
SELECT
  domain,
  createdAt
FROM `@project.datamint.leads`
WHERE industry IS NULL;
