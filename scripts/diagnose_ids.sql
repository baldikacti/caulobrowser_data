-- diagnose_ids.sql
-- Read-only. Shows exactly how the experiment_ids in results/*.csv filenames
-- differ from those in experiments.csv.
--
-- Usage:  BATCH_DIR=/abs/path/to/batch duckdb -f diagnose_ids.sql
-- (or run it via ./diagnose_ids.sh <batch_dir>)

CREATE OR REPLACE TEMP MACRO norm_id(s) AS nfc_normalize(
    replace(replace(replace(replace(replace(replace(
        s, chr(8710),   chr(916)),   -- ∆ INCREMENT
           chr(120491), chr(916)),   -- 𝚫 MATHEMATICAL BOLD
           chr(120549), chr(916)),   -- 𝛥 MATHEMATICAL ITALIC
           chr(120607), chr(916)),   -- 𝜟 MATHEMATICAL BOLD ITALIC
           chr(120665), chr(916)),   -- 𝝙 MATHEMATICAL SANS-SERIF BOLD
           chr(120723), chr(916))    -- 𝞓 MATHEMATICAL SANS-SERIF BOLD ITALIC
);

-- Renders the non-ASCII characters of a string as 'CHAR=U+XXXX' so that
-- visually identical characters can be told apart.
CREATE OR REPLACE TEMP MACRO codepoints(s) AS (
    SELECT COALESCE(string_agg(c || '=U+' || upper(printf('%04x', unicode(c))), ' '), '(all ASCII)')
    FROM (SELECT unnest(string_to_array(s, '')) AS c)
    WHERE unicode(c) > 127
);

CREATE OR REPLACE TEMP TABLE csv_ids AS
SELECT DISTINCT experiment_id
FROM read_csv(getenv('BATCH_DIR') || '/experiments.csv',
              header = true, types = {'experiment_id': 'VARCHAR'});

CREATE OR REPLACE TEMP TABLE file_ids AS
SELECT DISTINCT regexp_extract(file, '([^/]+)\.csv$', 1) AS experiment_id
FROM glob(getenv('BATCH_DIR') || '/results/*.csv');

.print ''
.print '=== 1. experiment_ids that do NOT match, comparing raw strings ==='
SELECT
    f.experiment_id                AS filename_id,
    codepoints(f.experiment_id)    AS filename_codepoints,
    CASE WHEN norm_id(f.experiment_id) IN (SELECT norm_id(experiment_id) FROM csv_ids)
         THEN 'yes -- fixed by normalization'
         ELSE 'NO -- still unmatched, see section 3'
    END                            AS matches_after_normalization
FROM file_ids f
WHERE f.experiment_id NOT IN (SELECT experiment_id FROM csv_ids)
ORDER BY 1;

.print ''
.print '=== 2. the corresponding rows in experiments.csv ==='
SELECT
    c.experiment_id             AS csv_id,
    codepoints(c.experiment_id) AS csv_codepoints
FROM csv_ids c
WHERE c.experiment_id NOT IN (SELECT experiment_id FROM file_ids)
ORDER BY 1;

.print ''
.print '=== 3. still unmatched after normalization (these need a real rename) ==='
SELECT f.experiment_id AS filename_id, codepoints(f.experiment_id) AS filename_codepoints
FROM file_ids f
WHERE norm_id(f.experiment_id) NOT IN (SELECT norm_id(experiment_id) FROM csv_ids)
ORDER BY 1;

.print ''
.print '=== 4. summary ==='
SELECT
    (SELECT count(*) FROM file_ids)  AS results_files,
    (SELECT count(*) FROM csv_ids)   AS experiments_rows,
    (SELECT count(*) FROM file_ids f
      WHERE f.experiment_id IN (SELECT experiment_id FROM csv_ids))          AS matched_raw,
    (SELECT count(*) FROM file_ids f
      WHERE norm_id(f.experiment_id) IN (SELECT norm_id(experiment_id) FROM csv_ids)) AS matched_normalized;
