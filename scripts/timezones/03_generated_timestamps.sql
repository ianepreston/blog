SELECT
  typeof(current_timestamp()) AS utc_type,
  current_timestamp() AS utc_ts,
  typeof(
    convert_timezone('America/Edmonton', current_timestamp())
  ) AS local_type,
  convert_timezone('America/Edmonton', current_timestamp()) AS local_ts;
