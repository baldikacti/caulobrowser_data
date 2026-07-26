#!/usr/bin/env bash
# Read-only. Compares experiment_ids in results/*.csv filenames against
#
# Usage: ./diagnose_ids.sh <batch_dir>

set -euo pipefail

[ $# -eq 1 ] || { echo "Usage: $0 <batch_dir>" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -d "$1" ] || { echo "Batch directory not found: $1" >&2; exit 1; }

export BATCH_DIR
BATCH_DIR="$(cd "$1" && pwd)"

duckdb -f "$SCRIPT_DIR/diagnose_ids.sql"
