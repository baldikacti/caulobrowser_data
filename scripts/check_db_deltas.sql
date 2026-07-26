-- check_db_deltas.sql
-- Read-only audit. Reports rows ALREADY IN the database whose text fields use a
-- delta variant other than U+0394. Batches ingested before fix_delta.sh existed
-- may contain U+2206, which fix_delta.sh does not touch (it only cleans input
-- files on disk).
--
-- Usage:  duckdb your_database.duckdb -f check_db_deltas.sql

CREATE OR REPLACE TEMP MACRO has_variant(s) AS
    s IS NOT NULL AND regexp_matches(s, '[' || chr(8710) || chr(120491) || chr(120549)
                                         || chr(120607) || chr(120665) || chr(120723) || ']');

CREATE OR REPLACE TEMP MACRO codepoints(s) AS (
    SELECT COALESCE(string_agg(c || '=U+' || upper(printf('%04x', unicode(c))), ' '), '')
    FROM (SELECT unnest(string_to_array(s, '')) AS c)
    WHERE unicode(c) > 127
);

.print ''
.print '=== experiments rows containing a non-canonical delta ==='
SELECT experiment_id, strain, genetic_background, display_label,
       codepoints(experiment_id) AS experiment_id_codepoints
FROM experiments
WHERE has_variant(experiment_id) OR has_variant(strain)
   OR has_variant(genetic_background) OR has_variant(display_label)
   OR has_variant(ref_strain) OR has_variant(treatment) OR has_variant(ref_treatment)
ORDER BY experiment_id;

.print ''
.print '=== de_results.experiment_id values containing a non-canonical delta ==='
SELECT experiment_id, count(*) AS n_rows, codepoints(experiment_id) AS codepoints
FROM de_results
WHERE has_variant(experiment_id)
GROUP BY experiment_id
ORDER BY experiment_id;

.print ''
.print '=== summary ==='
SELECT
    (SELECT count(*) FROM experiments)                              AS experiments_total,
    (SELECT count(*) FROM experiments WHERE has_variant(experiment_id)) AS experiments_needing_fix,
    (SELECT count(*) FROM de_results WHERE has_variant(experiment_id))  AS de_results_rows_affected;
