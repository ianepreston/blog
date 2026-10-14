WITH checks AS (
  SELECT *
  FROM VALUES
    (
      'before_change',
      TIMESTAMP_NTZ'2026-10-31 09:00:00',
      CAST('2026-10-31T15:00:00Z' AS TIMESTAMP)
    ),
    (
      'after_change',
      TIMESTAMP_NTZ'2026-11-02 09:00:00',
      CAST('2026-11-02T15:00:00Z' AS TIMESTAMP)
    ),
    (
      'future_winter',
      TIMESTAMP_NTZ'2027-01-15 09:00:00',
      CAST('2027-01-15T15:00:00Z' AS TIMESTAMP)
    )
  AS checks(test_case, local_ts, expected_utc_ts)
)
SELECT
  test_case,
  local_ts,
  to_utc_timestamp(
    local_ts,
    'America/Edmonton'
  ) AS actual_utc_ts,
  expected_utc_ts,
  to_utc_timestamp(
    local_ts,
    'America/Edmonton'
  ) = expected_utc_ts AS uses_current_alberta_rule
FROM checks
ORDER BY local_ts;
