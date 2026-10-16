WITH events AS (
  SELECT *
  FROM VALUES
    ('store_open', CAST('2026-01-15T16:30:00Z' AS TIMESTAMP)),
    ('late_batch', CAST('2026-01-16T02:15:00Z' AS TIMESTAMP))
  AS events(event_name, event_ts)
)
SELECT
  current_timezone() AS session_timezone,
  event_name,
  hour(event_ts) AS session_hour,
  hour(
    convert_timezone('America/Edmonton', event_ts)
  ) AS edmonton_hour,
  hour(
    convert_timezone('America/Edmonton', event_ts)
  ) BETWEEN 9 AND 16 AS during_business_hours
FROM events
ORDER BY event_ts;
