#!/usr/bin/env bash

set -euo pipefail

readonly profile="fevm-az-cc"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for sql_file in "${script_dir}"/*.sql; do
  echo
  echo "## $(basename "${sql_file}")"
  databricks experimental aitools tools query \
    --profile "${profile}" \
    --output json \
    --file "${sql_file}"
done
