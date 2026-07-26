# Experiment ingestion workfllow

This repository contains scripts and workflows to clean/update/create the database used by [Caulobrowser](https://github.com/baldikacti/caulobrowser) web application.

## Setup

1. Install [Duckdb](https://duckdb.org/install/?platform=macos&environment=cli) CLI, using the installation instructions on their website.
2. If you are worried and want to fix delta characters in your inputs, install the CLI tool from [here](https://github.com/baldikacti/fix_delta#installation).

## Files

| File                                       | Purpose                                                            |
| ------------------------------------------ | ------------------------------------------------------------------ |
| `fix_delta`                              | Canonicalize delta characters in a batch**before** ingesting |
| `ingest_batch.sh` / `ingest_batch.sql` | Validate and load a batch                                          |
| `diagnose_ids.sh` / `diagnose_ids.sql` | Read-only: compare filename vs CSV ids                             |
| `check_db_deltas.sql`                    | Read-only: audit an existing DB for non-canonical deltas           |

## Normal workflow

```bash
./scripts/fix_delta --fix-filenames data/input_data/results/**/*.csv
./scripts/ingest_batch.sh caulobrowser_test.duckdb data/input_data
```

## Diagnosing a mismatch

```bash
./scripts/diagnose_ids.sh data/input_data/
```

Prints every unmatched `experiment_id` with its non-ASCII characters spelled out
as codepoints, and whether normalization resolves it. Section 3 lists ids that
normalization *cannot* fix — those are genuine typos needing a real rename.

### Validation checks

Fatal, all inside one transaction — any failure rolls back and leaves the
database untouched:

- required fields present in `experiments.csv`
- no duplicate `experiment_id` in the batch, or against the existing DB
- no two experiment_ids ambiguous under delta normalization
- every `experiment_id` has a results file and vice versa
- every experiment retains at least one usable row after dropping
- no duplicate `(gene_id, experiment_id)` pairs
- every `gene_id` already exists in `genes`
