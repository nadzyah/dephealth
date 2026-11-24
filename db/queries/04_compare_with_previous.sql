-- What has changed since the previous assessment of the same manifest.
-- Matched on the fingerprint, since the manifest is not stored.
--
--   psql -v token=d225fa755e5477805d29aeecb7198387ea0364c8082f63f6968adfed890eb503 \
--        -f db/queries/04_compare_with_previous.sql

WITH this_report AS (
    SELECT id, manifest_fingerprint, created_at
      FROM dephealth.report
     WHERE token_digest = dephealth.report_token_digest(:'token')
),
previous_report AS (
    SELECT r.id, r.created_at
      FROM dephealth.report r
      JOIN this_report t ON r.manifest_fingerprint = t.manifest_fingerprint
     WHERE r.id <> t.id
       AND r.created_at < t.created_at
       AND r.withdrawn_at IS NULL
     ORDER BY r.created_at DESC
     LIMIT 1
)
SELECT coalesce(now_entry.package_name, then_entry.package_name) AS package_name,
       then_entry.risk_probability AS risk_then,
       now_entry.risk_probability  AS risk_now,
       round(now_entry.risk_probability - then_entry.risk_probability, 4) AS change,
       CASE
           WHEN then_entry.package_name IS NULL THEN 'new in the tree'
           WHEN now_entry.package_name IS NULL  THEN 'no longer in the tree'
           WHEN now_entry.risk_probability IS NULL
            AND then_entry.risk_probability IS NULL THEN 'still unresolved'
           WHEN now_entry.risk_probability > then_entry.risk_probability THEN 'risk has risen'
           WHEN now_entry.risk_probability < then_entry.risk_probability THEN 'risk has fallen'
           ELSE 'unchanged'
       END AS verdict
  FROM (SELECT e.* FROM dephealth.report_entry e JOIN this_report t ON t.id = e.report_id) now_entry
  FULL JOIN (SELECT e.* FROM dephealth.report_entry e JOIN previous_report p ON p.id = e.report_id) then_entry
         ON lower(then_entry.package_name) = lower(now_entry.package_name)
 ORDER BY change DESC NULLS LAST, package_name;
