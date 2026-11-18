-- K-Medoids (simplified PAM) with Gower distance for mixed-type data.
-- Implemented with BigQuery scripting and a JavaScript UDF.
-- Replace @project with your GCP project id before running.
--
-- How to run:
--   1) create the UDFs (CREATE FUNCTION) once;
--   2) run the whole scripting block (BEGIN ... END) on a schedule or manually
--      after each refresh of `enrichment_data_transformed`.

-- ===========================================================================
-- JavaScript UDF: Gower distance between two organizations.
-- d(i,j) = (1/p) * Σ d_k(i_k, j_k), where each d_k is normalized to [0, 1].
-- Categorical (industry, country): 0 if equal, 1 otherwise.
-- Numeric (size): normalized absolute difference |x_i - x_j| / range.
-- A feature that is NULL on either side is excluded from the sum.
-- ===========================================================================
CREATE OR REPLACE FUNCTION `@project.datamint.gower_distance`(
  a STRUCT<industry STRING, country STRING, size FLOAT64>,
  b STRUCT<industry STRING, country STRING, size FLOAT64>,
  size_range FLOAT64
)
RETURNS FLOAT64
LANGUAGE js
AS r"""
  let p = 0;
  let sum = 0;

  if (a.industry !== null && b.industry !== null) {
    sum += (a.industry === b.industry ? 0 : 1);
    p++;
  }
  if (a.country !== null && b.country !== null) {
    sum += (a.country === b.country ? 0 : 1);
    p++;
  }
  if (a.size !== null && b.size !== null && size_range > 0) {
    sum += Math.abs(a.size - b.size) / size_range;
    p++;
  }

  return p === 0 ? 1.0 : sum / p;
""";

-- ===========================================================================
-- SQL UDF: company-size bucket string → numeric midpoint (for Gower).
-- '1. 0-1' → 0.5, '5. 201-500' → 350, '9. 10,001+' → 15000, and so on.
-- ===========================================================================
CREATE OR REPLACE FUNCTION `@project.datamint.size_bucket_to_numeric`(s STRING)
RETURNS FLOAT64
AS (
  CASE s
    WHEN '1. 0-1'           THEN     0.5
    WHEN '2. 2-10'          THEN     6.0
    WHEN '3. 11-50'         THEN    30.0
    WHEN '4. 51-200'        THEN   125.0
    WHEN '5. 201-500'       THEN   350.0
    WHEN '6. 501-1,000'     THEN   750.0
    WHEN '7. 1,001-5,000'   THEN  3000.0
    WHEN '8. 5,001-10,000'  THEN  7500.0
    WHEN '9. 10,001+'       THEN 15000.0
  END
);

-- ===========================================================================
-- PAM script: iterative medoid improvement.
-- A deliberately simple variant:
--   1) random initialization of k medoids;
--   2) repeat max_iter times:
--      a) assign every object to its nearest medoid;
--      b) in each cluster pick the new medoid = the object with the minimal
--         sum of distances to the other objects of that cluster;
--   3) final assignment → MERGE cluster_id into leads.
-- ===========================================================================
BEGIN
  DECLARE k INT64 DEFAULT 4;
  DECLARE max_iter INT64 DEFAULT 5;
  DECLARE iter INT64 DEFAULT 0;
  DECLARE size_min FLOAT64;
  DECLARE size_max FLOAT64;
  DECLARE size_range FLOAT64;

  -- The numeric feature's range is needed to normalize it in Gower.
  SET (size_min, size_max) = (
    SELECT AS STRUCT
      MIN(`@project.datamint.size_bucket_to_numeric`(size)),
      MAX(`@project.datamint.size_bucket_to_numeric`(size))
    FROM `@project.datamint.enrichment_data_transformed`
    WHERE size IS NOT NULL
  );
  SET size_range = GREATEST(IFNULL(size_max, 0) - IFNULL(size_min, 0), 1.0);

  -- Initial medoids: k random objects with a COMPLETE profile
  -- (industry, country and size all non-NULL). This is an interpretability
  -- heuristic: a medoid should be a typical representative of its segment,
  -- and a NULL feature makes it useless for business interpretation.
  CREATE OR REPLACE TABLE `@project.datamint.cluster_medoids` AS
  SELECT
    ROW_NUMBER() OVER () AS cluster_id,
    domain, industry, country, size
  FROM (
    SELECT
      domain,
      industry,
      country,
      `@project.datamint.size_bucket_to_numeric`(size) AS size
    FROM `@project.datamint.enrichment_data_transformed`
    WHERE industry IS NOT NULL
      AND industry != 'unknown'
      AND country IS NOT NULL
      AND size IS NOT NULL
    ORDER BY RAND()
    LIMIT 4   -- = k; BigQuery does not accept a variable in LIMIT, so keep in sync
  );

  WHILE iter < max_iter DO
    -- Step 1: assign every object to its nearest medoid.
    CREATE OR REPLACE TEMP TABLE assignments AS
    WITH points AS (
      SELECT
        domain,
        industry,
        country,
        `@project.datamint.size_bucket_to_numeric`(size) AS size
      FROM `@project.datamint.enrichment_data_transformed`
      WHERE industry IS NOT NULL
    ),
    distances AS (
      SELECT
        p.domain, p.industry, p.country, p.size,
        m.cluster_id,
        `@project.datamint.gower_distance`(
          STRUCT(p.industry, p.country, p.size),
          STRUCT(m.industry, m.country, m.size),
          size_range
        ) AS dist
      FROM points p
      CROSS JOIN `@project.datamint.cluster_medoids` m
    )
    SELECT domain, industry, country, size, cluster_id, dist
    FROM distances
    QUALIFY ROW_NUMBER() OVER (PARTITION BY domain ORDER BY dist ASC) = 1;

    -- Step 2: in each cluster pick the object with the minimal total
    -- within-cluster distance as the new medoid (the PAM objective:
    -- min Σ d(p, m)). Only objects with a complete profile can become medoids
    -- (the same interpretability heuristic as at initialization); the other
    -- points `b` stay unfiltered, because Gower handles NULLs by skipping them.
    CREATE OR REPLACE TABLE `@project.datamint.cluster_medoids` AS
    WITH pairwise AS (
      SELECT
        a.cluster_id,
        a.domain AS candidate_domain,
        a.industry AS candidate_industry,
        a.country AS candidate_country,
        a.size AS candidate_size,
        SUM(
          `@project.datamint.gower_distance`(
            STRUCT(a.industry, a.country, a.size),
            STRUCT(b.industry, b.country, b.size),
            size_range
          )
        ) AS total_dist
      FROM assignments a
      JOIN assignments b
        ON a.cluster_id = b.cluster_id AND a.domain != b.domain
      WHERE a.industry IS NOT NULL
        AND a.country IS NOT NULL
        AND a.size IS NOT NULL
      GROUP BY 1, 2, 3, 4, 5
    )
    SELECT
      cluster_id,
      candidate_domain AS domain,
      candidate_industry AS industry,
      candidate_country AS country,
      candidate_size AS size
    FROM pairwise
    QUALIFY ROW_NUMBER() OVER (PARTITION BY cluster_id ORDER BY total_dist ASC) = 1;

    SET iter = iter + 1;
  END WHILE;

  -- Final step: MERGE cluster_id into leads.
  MERGE `@project.datamint.leads` L
  USING (
    WITH points AS (
      SELECT
        domain,
        industry,
        country,
        `@project.datamint.size_bucket_to_numeric`(size) AS size
      FROM `@project.datamint.enrichment_data_transformed`
      WHERE industry IS NOT NULL
    ),
    distances AS (
      SELECT
        p.domain,
        m.cluster_id,
        `@project.datamint.gower_distance`(
          STRUCT(p.industry, p.country, p.size),
          STRUCT(m.industry, m.country, m.size),
          size_range
        ) AS dist
      FROM points p
      CROSS JOIN `@project.datamint.cluster_medoids` m
    )
    SELECT domain, cluster_id
    FROM distances
    QUALIFY ROW_NUMBER() OVER (PARTITION BY domain ORDER BY dist ASC) = 1
  ) S
  ON L.domain = S.domain
  WHEN MATCHED THEN UPDATE SET cluster_id = S.cluster_id;
END;
