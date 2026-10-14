SELECT
  current_timezone() AS session_timezone,
  typeof(CAST('2026-01-15T16:00:00Z' AS TIMESTAMP)) AS instant_type,
  CAST('2026-01-15T16:00:00Z' AS TIMESTAMP) AS instant_ts,
  typeof(TIMESTAMP_NTZ'2026-01-15 09:00:00') AS wall_clock_type,
  TIMESTAMP_NTZ'2026-01-15 09:00:00' AS wall_clock_ts;
