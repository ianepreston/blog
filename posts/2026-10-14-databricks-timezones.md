---
title: "Time zones when moving from on-prem to Databricks"
date: "2026-10-14"
description: "UTC, local time, and how to avoid being surprised by either"
layout: "post"
toc: true
categories: [databricks, sql]
---

# Introduction

Time zones are one of those topics that seem straightforward right up until
they aren't. This gets particularly confusing for companies moving from
on-prem systems to the cloud.

An on-prem system might have spent its entire life in one data centre and one
time zone. A value like `2026-01-15 09:00:00` was obviously local time because
everything was local time. Once that data lands in a cloud platform it starts
mixing with audit columns, system tables, APIs, and services that record time in
UTC. Now that same value is ambiguous: is it nine in the morning in Edmonton,
or nine in the morning UTC?

This post covers how I handle that in Databricks. The short version is:

- Use `TIMESTAMP` for an instant in time, normalized to UTC.
- Use `TIMESTAMP_NTZ` for a wall-clock value with no time zone attached.
- Convert explicitly when writing data instead of relying on a session setting.
- Use names and comments that make the intended time zone obvious.

I'll use `America/Edmonton` for the local time zone in the examples, but the
same approach applies to any [IANA time zone](https://www.iana.org/time-zones).

# Two timestamp types that mean different things

Databricks has two timestamp types that matter here.

[`TIMESTAMP`](https://learn.microsoft.com/en-us/azure/databricks/sql/language-manual/data-types/timestamp-type)
represents an instant in time. Databricks normalizes that instant to UTC, then
renders it using the current session time zone. Change the session time zone
and the displayed clock time changes, but the instant does not.

[`TIMESTAMP_NTZ`](https://learn.microsoft.com/en-us/azure/databricks/sql/language-manual/data-types/timestamp-ntz-type)
represents a wall-clock value. The `NTZ` means "no time zone." The value does
not move when the session time zone changes. That makes it a good fit for a
source value that means "09:00 in the local office," but the type does not
remember which office or time zone you meant. Column names and comments still
matter.

Here's a small example from a SQL warehouse configured for UTC:

```sql
SELECT
  current_timezone() AS session_timezone,
  typeof(CAST('2026-01-15T16:00:00Z' AS TIMESTAMP)) AS instant_type,
  CAST('2026-01-15T16:00:00Z' AS TIMESTAMP) AS instant_ts,
  typeof(TIMESTAMP_NTZ'2026-01-15 09:00:00') AS wall_clock_type,
  TIMESTAMP_NTZ'2026-01-15 09:00:00' AS wall_clock_ts;
```

| session_timezone | instant_type | instant_ts              | wall_clock_type | wall_clock_ts       |
| ---------------- | ------------ | ----------------------- | --------------- | ------------------- |
| Etc/UTC          | timestamp    | 2026-01-15 16:00:00 UTC | timestamp_ntz   | 2026-01-15 09:00:00 |

If I change the session to `America/Edmonton`, the instant displays as 09:00.
The `TIMESTAMP_NTZ` value also displays as 09:00, but for a completely different
reason: its clock value never changes. Identical output does not mean identical
semantics.

# Converting local source data to UTC

Let's say an older source system exports timestamps as strings and all of them
are known to be Edmonton time. I want to preserve the value the source supplied
and also create an unambiguous instant for joins, ordering, and comparisons.

```sql
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
```

| local_ts            | utc_ts                  |
| ------------------- | ----------------------- |
| 2026-01-15 09:00:00 | 2026-01-15 16:00:00 UTC |
| 2026-07-15 09:00:00 | 2026-07-15 15:00:00 UTC |

The different UTC values are intentional. Edmonton is seven hours behind UTC
in January and six hours behind in July. Using the named time zone lets the
conversion function apply daylight-saving rules. Subtracting a fixed number of
hours would be wrong for half the year.

Those offsets are correct for the example dates in early and mid-2026. They
are not the rules Alberta will use going forward. Alberta has
[adopted permanent Alberta Time](https://www.alberta.ca/albertas-new-time-system-abt),
equivalent to UTC-6, and clocks will no longer fall back to Mountain Standard
Time beginning in November 2026. A January 2027 value should therefore also be
six hours behind UTC.

## Named time zones still depend on current data

Using `America/Edmonton` instead of subtracting a hard-coded offset is still
the right approach, but it only works if the runtime has a current copy of the
[IANA time-zone database](https://www.iana.org/time-zones). Alberta's new rules
were added in tzdata 2026c.

As of October 14, 2026, the serverless SQL warehouse I used for this post had
not received that update. I added this query to the validation scripts so I can
tell when the update arrives:

```sql
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
```

| test_case      | local_ts            | actual_utc_ts           | expected_utc_ts         | current_rule |
| -------------- | ------------------- | ----------------------- | ----------------------- | ------------ |
| before_change  | 2026-10-31 09:00:00 | 2026-10-31 15:00:00 UTC | 2026-10-31 15:00:00 UTC | true         |
| after_change   | 2026-11-02 09:00:00 | 2026-11-02 16:00:00 UTC | 2026-11-02 15:00:00 UTC | false        |
| future_winter  | 2027-01-15 09:00:00 | 2027-01-15 16:00:00 UTC | 2027-01-15 15:00:00 UTC | false        |

The pre-change result is correct, but the two winter results still use the old
UTC-7 rule. Once the warehouse has current time-zone data, the last column
should be `true` for all three rows without changing the conversion code. This
is also a good reminder to test future dates whenever local time-zone rules are
changing; using a named zone is necessary, but the runtime data behind that
name matters too.

For a table that needs both representations I would use a schema something like
this:

```sql
CREATE TABLE events (
  event_id BIGINT,
  event_utc_ts TIMESTAMP
    COMMENT 'Event instant normalized to UTC',
  event_local_ts TIMESTAMP_NTZ
    COMMENT 'Source wall-clock time in America/Edmonton'
);
```

The suffixes are a little verbose, but timestamp bugs are worse. If local time
does not have independent business meaning, storing the UTC instant plus an
IANA time-zone identifier and deriving the local value is also reasonable. The
important thing is not to leave the interpretation implicit.

When adding a `TIMESTAMP_NTZ` column to an older Delta table you may first need
to enable the table feature:

```sql
ALTER TABLE events
SET TBLPROPERTIES ('delta.feature.timestampNtz' = 'supported');
```

New Delta tables with a `TIMESTAMP_NTZ` column enable the feature automatically.

# Timestamps generated in Databricks

For timestamps created in Databricks the conversion goes the other direction.
`current_timestamp()` returns a `TIMESTAMP`, so it is already the right type for
the UTC instant column. `convert_timezone()` can produce the corresponding
local `TIMESTAMP_NTZ` value.

```sql
SELECT
  typeof(current_timestamp()) AS utc_type,
  current_timestamp() AS utc_ts,
  typeof(
    convert_timezone('America/Edmonton', current_timestamp())
  ) AS local_type,
  convert_timezone('America/Edmonton', current_timestamp()) AS local_ts;
```

This was the result when I ran the example:

| utc_type  | utc_ts                  | local_type    | local_ts            |
| --------- | ----------------------- | ------------- | ------------------- |
| timestamp | 2026-10-14 18:41:17 UTC | timestamp_ntz | 2026-10-14 12:41:17 |

The code is explicit about the local zone, so it produces the same pair of
values whether the SQL warehouse session is configured for UTC, Edmonton, or
something else.

# Why the session time zone can still surprise you

The session setting controls how `TIMESTAMP` values are presented and how
functions such as `hour()` interpret them. That means business logic can change
based on a setting far away from the query.

Here's an example using a UTC warehouse:

```sql
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
```

| session_timezone | event_name | session_hour | edmonton_hour | during_business_hours |
| ---------------- | ---------- | -----------: | ------------: | --------------------- |
| Etc/UTC          | store_open |           16 |             9 | true                  |
| Etc/UTC          | late_batch |            2 |            19 | false                 |

`hour(event_ts)` is not inherently a UTC hour. It is the hour in the current
session time zone. The explicit conversion makes the business rule independent
of that setting.

# Setting the session time zone consistently

Explicit conversion should handle correctness, but a consistent session time
zone is still useful for interactive work.

For one SQL session:

```sql
SET TIME ZONE 'America/Edmonton';
```

For a notebook or job:

```python
spark.conf.set("spark.sql.session.timeZone", "America/Edmonton")
```

A workspace administrator can also add the following SQL configuration
parameter to apply it to SQL warehouses:

```text
spark.sql.session.timeZone America/Edmonton
```

That workspace setting does not configure jobs or interactive compute. More
importantly, none of these settings document what a source value meant. I treat
them as display conveniences, not as a substitute for explicit conversion.

# Validating the examples

I kept the SQL used for this post in the blog repository. This command runs all
five examples against my Databricks workspace and prints the results as JSON:

```bash
./scripts/timezones/validate.sh
```

The script uses the `fevm-az-cc` Databricks CLI profile. If you're adapting it
for your own environment, change the profile near the top of the script.

# Conclusion

There isn't a setting that makes time zones stop being complicated. My general
approach is to store an unambiguous `TIMESTAMP` for operations that care about
an instant, preserve a `TIMESTAMP_NTZ` when the original wall-clock value has
business meaning, and make every conversion explicit.

It costs a little extra storage and typing. In exchange, joins against system
tables work, daylight-saving changes are handled correctly, and downstream
users do not have to guess what `created_at` meant. That seems like a pretty
good trade to me.
