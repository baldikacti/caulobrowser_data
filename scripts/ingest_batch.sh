#!/usr/bin/env bash
# Validates and loads one batch of new experiments into the database.
#
# Usage: ./ingest_batch.sh <db_path> <batch_dir>
#
# batch_dir must contain:
#   experiments.csv
#   results/<experiment_id>.csv   -- one file per row in experiments.csv,
#                                     named exactly after that row's experiment_id

set -euo pipefail

usage() {
    echo "Usage: $0 <db_path> <batch_dir>" >&2
    echo "  batch_dir must contain:" >&2
    echo "    experiments.csv" >&2
    echo "    results/<experiment_id>.csv  (one file per experiment_id row)" >&2
    exit 1
}

[ $# -eq 2 ] || usage

DB_PATH="$1"
RAW_BATCH_DIR="$2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_SCRIPT="$SCRIPT_DIR/ingest_batch.sql"

command -v duckdb >/dev/null 2>&1 || { echo "duckdb CLI not found on PATH" >&2; exit 1; }
[ -f "$DB_PATH" ] || { echo "Database not found: $DB_PATH" >&2; exit 1; }
[ -d "$RAW_BATCH_DIR" ] || { echo "Batch directory not found: $RAW_BATCH_DIR" >&2; exit 1; }
[ -f "$RAW_BATCH_DIR/experiments.csv" ] || { echo "Missing $RAW_BATCH_DIR/experiments.csv" >&2; exit 1; }
[ -d "$RAW_BATCH_DIR/results" ] || { echo "Missing $RAW_BATCH_DIR/results/ directory" >&2; exit 1; }
[ -f "$SQL_SCRIPT" ] || { echo "Missing $SQL_SCRIPT (expected next to this script)" >&2; exit 1; }

# Absolute path -- getenv('BATCH_DIR') is read inside ingest_batch.sql and
# must not depend on the caller's current directory.
export BATCH_DIR
BATCH_DIR="$(cd "$RAW_BATCH_DIR" && pwd)"

echo "Batch directory: $BATCH_DIR"
echo "Database:        $DB_PATH"
echo

if duckdb -bail "$DB_PATH" -f "$SQL_SCRIPT"; then
    echo
    echo "Batch ingested successfully."
else
    echo
    echo "Ingestion FAILED -- transaction was not committed, database is unchanged." >&2
    exit 1
fi
