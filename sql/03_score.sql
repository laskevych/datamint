-- BigQuery Scheduled Query: classify leads into four SQL-qualified categories
-- (Yes / Probably Yes / No / Unknown) using a white-box rule-based CASE.
-- Inputs are the three canonical signals from enrichment_data_transformed:
-- country_flag, industry_is_sql_size, size.
-- Replace @project before running.

MERGE `@project.datamint.leads` L
USING (
  SELECT
    domain,
    industry,
    size,
    country,
    createdAt,
    CASE
      /* 'No' — any disqualifying signal */
      WHEN
        country_flag = 'No'
        OR industry_is_sql_size IS FALSE
        OR size IN ('1. 0-1', '2. 2-10', '3. 11-50', '4. 51-200')
      THEN 'No'

      /* 'Yes' — all signals positive */
      WHEN
        country_flag = 'Yes'
        AND industry_is_sql_size = TRUE
        AND size IN ('5. 201-500', '6. 501-1,000',
                     '7. 1,001-5,000', '8. 5,001-10,000', '9. 10,001+')
      THEN 'Yes'

      /* 'Unknown' — no signal at all (the company was not enriched) */
      WHEN
        country_flag IS NULL
        AND industry_is_sql_size IS NULL
        AND size IS NULL
      THEN 'Unknown'

      /* 'Probably Yes' — every signal positive or NULL, at least one positive */
      WHEN
        (country_flag = 'Yes' OR country_flag IS NULL)
        AND (industry_is_sql_size = TRUE OR industry_is_sql_size IS NULL)
        AND (size IN ('5. 201-500', '6. 501-1,000',
                      '7. 1,001-5,000', '8. 5,001-10,000', '9. 10,001+')
             OR size IS NULL)
      THEN 'Probably Yes'

      ELSE 'Unknown'
    END AS sqlSize
  FROM `@project.datamint.enrichment_data_transformed`
) S
ON L.domain = S.domain
WHEN MATCHED THEN UPDATE SET
  industry = S.industry,
  size = S.size,
  country = S.country,
  sqlSize = S.sqlSize
WHEN NOT MATCHED THEN INSERT (domain, industry, size, country, sqlSize, createdAt)
VALUES (S.domain, S.industry, S.size, S.country, S.sqlSize, S.createdAt);
