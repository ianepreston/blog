SELECT
  CAST(source_time AS TIMESTAMP_NTZ) AS local_ts,
  to_utc_timestamp(
    CAST(source_time AS TIMESTAMP_NTZ),
    'America/Edmonton'
  ) AS utc_ts
FROM VALUES
  ('2026-01-15 09:00:00'),
  ('2026-07-15 09:00:00')
AS source(source_time);
