-- ingest_batch.sql
-- Validates one batch (experiments.csv + results/*.csv) and, only if every
-- check passes, commits it into experiments / de_results in a single
-- transaction. Not meant to be run directly -- use ingest_batch.sh.
--
-- Expects the BATCH_DIR environment variable to be set to an absolute path
-- containing:
--   experiments.csv
--   results/<experiment_id>.csv   (one file per row in experiments.csv)

.bail on

-- Renders non-ASCII characters as 'X=U+XXXX' for legible error messages.
CREATE OR REPLACE TEMP MACRO codepoints(s) AS (
    SELECT COALESCE(string_agg(c || '=U+' || upper(printf('%04x', unicode(c))), ' '), '')
    FROM (SELECT unnest(string_to_array(s, '')) AS c)
    WHERE unicode(c) > 127
);

BEGIN TRANSACTION;

-- Load experiments.csv with an explicit schema.

CREATE OR REPLACE TEMP TABLE stg_experiments AS
SELECT
    experiment_id,
    display_label,
    experiment_class,
    data_type,
    strain,
    genetic_background,
    treatment,
    treatment_level,
    growth_phase,
    media,
    ref_strain,
    ref_treatment,
    ref_treatment_level,
    ref_growth_phase,
    ref_media,
    stat_method,
    lab_group,
    doi,
    notes,
    geo_id,
    COALESCE(date_added, current_date) AS date_added
FROM read_csv(
    getenv('BATCH_DIR') || '/experiments.csv',
    header  = true,
    nullstr = ['', 'NA', 'NaN', 'N/A', 'na', 'n/a', 'NULL', 'null'],
    columns = {
        'experiment_id':       'VARCHAR',
        'display_label':       'VARCHAR',
        'experiment_class':    'VARCHAR',
        'data_type':           'VARCHAR',
        'strain':              'VARCHAR',
        'genetic_background':  'VARCHAR',
        'treatment':           'VARCHAR',
        'treatment_level':     'VARCHAR',
        'growth_phase':        'VARCHAR',
        'media':               'VARCHAR',
        'ref_strain':          'VARCHAR',
        'ref_treatment':       'VARCHAR',
        'ref_treatment_level': 'VARCHAR',
        'ref_growth_phase':    'VARCHAR',
        'ref_media':           'VARCHAR',
        'stat_method':         'VARCHAR',
        'lab_group':           'VARCHAR',
        'doi':                 'VARCHAR',
        'geo_id':              'VARCHAR',
        'notes':               'VARCHAR',
        'date_added':          'DATE'
    }
);

-- Checks are wrapped in CREATE TEMP TABLE ... AS so the CLI doesn't print an
-- empty result table for every check that passes. error() still fires normally.

CREATE OR REPLACE TEMP TABLE _chk AS
SELECT error('experiments.csv: missing required field(s) in row(s): ' || ids)
FROM (
    SELECT string_agg(COALESCE(experiment_id, '<null id>'), ', ') AS ids
    FROM stg_experiments
    WHERE experiment_id IS NULL OR display_label IS NULL
       OR experiment_class IS NULL OR data_type IS NULL
)
WHERE ids IS NOT NULL;

CREATE OR REPLACE TEMP TABLE _chk AS
SELECT error('experiments.csv: duplicate experiment_id in batch: ' || ids)
FROM (
    SELECT string_agg(experiment_id, ', ') AS ids
    FROM (SELECT experiment_id FROM stg_experiments GROUP BY experiment_id HAVING count(*) > 1)
)
WHERE ids IS NOT NULL;

CREATE OR REPLACE TEMP TABLE _chk AS
SELECT error('experiments.csv: experiment_id already exists in DB: ' || ids)
FROM (
    SELECT string_agg(s.experiment_id, ', ') AS ids
    FROM stg_experiments s
    JOIN experiments e USING (experiment_id)
)
WHERE ids IS NOT NULL;


-- Load every results/*.csv, tagging each row with the
-- experiment_id taken from its filename.

CREATE OR REPLACE TEMP TABLE stg_results_raw AS
SELECT
    gene_id,
    regexp_extract(filename, '([^/]+)\.csv$', 1) AS file_experiment_id,
    log2fc,
    stat_value
FROM read_csv(
    getenv('BATCH_DIR') || '/results/*.csv',
    header        = true,
    filename      = true,
    union_by_name = true,
    nullstr       = ['', 'NA', 'NaN', 'N/A', 'na', 'n/a', 'NULL', 'null'],
    types         = {
        'gene_id':    'VARCHAR',
        'log2fc':     'DOUBLE',
        'stat_value': 'DOUBLE'
    }
);

-- Resolve each filename to the experiment_id spelled in experiments.csv.
-- experiments.csv is the source of truth for the stored value, so
-- de_results.experiment_id always matches experiments.experiment_id.
CREATE OR REPLACE TEMP TABLE stg_results_resolved AS
SELECT
    r.gene_id,
    e.experiment_id,
    r.file_experiment_id,
    r.log2fc,
    r.stat_value
FROM stg_results_raw r
LEFT JOIN stg_experiments e
       ON r.file_experiment_id = e.experiment_id;

-- every results file must correspond to a row in experiments.csv
CREATE OR REPLACE TEMP TABLE _chk AS
SELECT error('results file(s) with no matching row in experiments.csv: ' || ids
             || '  [run diagnose_ids.sql for a codepoint-level comparison]')
FROM (
    SELECT string_agg(
               file_experiment_id
               || CASE WHEN codepoints(file_experiment_id) <> ''
                       THEN ' (' || codepoints(file_experiment_id) || ')'
                       ELSE '' END,
               ', ') AS ids
    FROM (SELECT DISTINCT file_experiment_id FROM stg_results_resolved WHERE experiment_id IS NULL)
)
WHERE ids IS NOT NULL;

-- Drop rows missing any required value. stat_value is nullable by design and
-- is never a reason to drop a row -- an all-NA stat_value column is fine.
CREATE OR REPLACE TEMP TABLE stg_results AS
SELECT gene_id, experiment_id, log2fc, stat_value
FROM stg_results_resolved
WHERE gene_id       IS NOT NULL
  AND experiment_id IS NOT NULL
  AND log2fc        IS NOT NULL
  AND NOT isnan(log2fc);

-- Report what was dropped (informational, not fatal).
SELECT
    file_experiment_id AS experiment,
    count(*) AS rows_dropped,
    count(*) FILTER (WHERE gene_id IS NULL)                 AS missing_gene_id,
    count(*) FILTER (WHERE log2fc IS NULL OR isnan(log2fc)) AS missing_log2fc
FROM stg_results_resolved
WHERE gene_id IS NULL OR experiment_id IS NULL
   OR log2fc IS NULL OR isnan(log2fc)
GROUP BY file_experiment_id
ORDER BY file_experiment_id;

-- every experiment in the batch must have a results file
CREATE OR REPLACE TEMP TABLE _chk AS
SELECT error('experiment(s) in experiments.csv with no results file: ' || ids)
FROM (
    SELECT string_agg(experiment_id, ', ') AS ids
    FROM stg_experiments
    WHERE experiment_id NOT IN
          (SELECT DISTINCT file_experiment_id FROM stg_results_raw)
)
WHERE ids IS NOT NULL;

CREATE OR REPLACE TEMP TABLE _chk AS
SELECT error('experiment(s) whose every result row was dropped as incomplete: ' || ids)
FROM (
    SELECT string_agg(experiment_id, ', ') AS ids
    FROM stg_experiments
    WHERE experiment_id NOT IN (SELECT DISTINCT experiment_id FROM stg_results)
)
WHERE ids IS NOT NULL;

-- no duplicate (gene_id, experiment_id) pairs within the batch
CREATE OR REPLACE TEMP TABLE _chk AS
SELECT error('de_results: duplicate gene_id/experiment_id pairs: ' || ids)
FROM (
    SELECT string_agg(gene_id || '/' || experiment_id, ', ') AS ids
    FROM (
        SELECT gene_id, experiment_id FROM stg_results
        GROUP BY gene_id, experiment_id HAVING count(*) > 1
    )
)
WHERE ids IS NOT NULL;

-- every gene_id must already exist in genes (readable error instead of a
-- raw foreign-key violation)
CREATE OR REPLACE TEMP TABLE _chk AS
SELECT error('de_results: unknown gene_id(s) not in genes table: ' || ids)
FROM (
    SELECT string_agg(gene_id, ', ') AS ids
    FROM (SELECT DISTINCT s.gene_id FROM stg_results s
          WHERE NOT EXISTS (SELECT 1 FROM genes g WHERE g.gene_id = s.gene_id))
)
WHERE ids IS NOT NULL;

-- All checks passed -- commit into the real tables.
INSERT INTO experiments SELECT * FROM stg_experiments;

INSERT INTO de_results (gene_id, experiment_id, log2fc, stat_value)
SELECT gene_id, experiment_id, log2fc, stat_value FROM stg_results;

INSERT INTO ingest_log (batch_dir, n_experiments, n_results, n_results_dropped, status)
SELECT
    getenv('BATCH_DIR'),
    (SELECT count(*) FROM stg_experiments),
    (SELECT count(*) FROM stg_results),
    (SELECT count(*) FROM stg_results_resolved) - (SELECT count(*) FROM stg_results),
    'success';

COMMIT;
