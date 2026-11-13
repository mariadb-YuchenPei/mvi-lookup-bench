# Benchmark design: MariaDB multi-valued index vs PostgreSQL GIN

Draft, 2026-11-13.

This document plans benchmark runs comparing MariaDB's multi-valued index
(MVI, MDEV-25848) with PostgreSQL's GIN index on JSONB, for reads and for
writes. The current `mvi_test.lua` covers only R1 below. Every
"Expectation" here is a hypothesis from how the two indexes are built; the
point of the runs is to confirm or refute it.

## How the two indexes differ

| Aspect              | MariaDB MVI                                                        | PostgreSQL GIN (`jsonb_path_ops`)                                         |
|---------------------|--------------------------------------------------------------------|---------------------------------------------------------------------------|
| Structure           | side B-tree table `(typ, value, tref)`, one row per array element   | key -> posting list (or posting tree) of row IDs                          |
| Keys                | type + value; strings over 16 bytes become a hash                   | a 32-bit hash of path and value; every match is rechecked                 |
| What it indexes     | one array column, i.e. one fixed path                              | an expression or the whole document; `@>` at any path                     |
| Read path           | B-tree probe, then one `rnd_pos()` per row, in index order          | bitmap index scan, then bitmap heap scan in physical order                |
| Several values, AND | keeps the cheapest value, rechecks the rest                        | intersects posting lists                                                  |
| Several values, OR  | one scan over all values, skipping duplicate rows                   | OR of bitmaps                                                             |
| With other indexes  | index_merge `sort_union` only (not ROR; `sort_intersect` off)       | BitmapAnd / BitmapOr across any indexes                                   |
| Joins               | range only for constant values; no `ref` access                     | parameterized bitmap scans in nested loops                                |
| Estimates           | `records_in_range()` dives, real counts                             | fixed selectivity for `@>`; weak jsonb statistics                         |
| Writes              | side-table rows inserted/deleted in the statement                   | direct insert, or a pending list (`fastupdate`) merged later              |
| Indexes per table   | one hlindex                                                        | any number                                                                |

## Systems and setup

- **MariaDB**: a build with MDEV-25848 (`bb-main-todo-6385`), InnoDB.
  Table layout: `attributes JSON` holding the bare tags array,
  `INDEX (CAST(attributes AS CHAR(32) ARRAY))`.
- **PostgreSQL**: a current release. Two index variants, run separately:
  - `pg`: `GIN ((attributes->'tags') jsonb_path_ops)` on `{"tags": [...]}`,
    as in `mvi_test.lua` today;
  - `pg_array`: a `text[]` column with `GIN (tags)` (`array_ops`). This is
    the closest PostgreSQL equivalent of one indexed array column, without
    JSON overhead.
- **Both**:
  - the largest table and its indexes fit in memory (InnoDB buffer pool,
    `shared_buffers`), unless a run says otherwise;
  - server pinned to the P-cores, sysbench to the E-cores
    (`run-mvi-benchmark.sh <server> <threads> <cpus>`);
  - CPU frequency fixed (`performance` governor, turbo off) where possible;
  - each run repeated 3-5 times, medians reported; 60-120 s per run after a
    warm-up;
  - PostgreSQL: autovacuum on (as in production), `ANALYZE` after loading;
    GIN `fastupdate` on (default), with an extra run with it off for the
    write workloads.
- **Thread counts**: 1, 4 and 8 (one per server hardware thread). 1 shows
  per-query cost; 8 shows scaling.

## Data sets

| Name      | Tags per row         | Tag distribution                 | Purpose                                     |
|-----------|----------------------|----------------------------------|---------------------------------------------|
| `uniform` | 1-2 (current)        | uniform over `table_size` values | selective lookups, about 1.5 rows per value |
| `skewed`  | 1-5                  | Zipf over 10 000 values          | common and rare values in the same table    |
| `long`    | 20-50                | uniform over 100 000 values      | large arrays: index size, write cost        |
| `strings` | 1-2                  | uniform; values over 16 bytes    | MariaDB's hashed strings vs short strings   |
| `numbers` | 1-2                  | uniform integers                 | number encoding and equality                |

Table sizes: 100k, 1M, 10M rows (10M only for `uniform` and `skewed`). The
same random seed is used for every server, so all servers hold the same
data.

## Read workloads

| #  | Workload                          | MariaDB                                                          | PostgreSQL (`pg`)                                          | Expectation and reasoning |
|----|-----------------------------------|------------------------------------------------------------------|------------------------------------------------------------|---------------------------|
| R1 | Selective single value (current)  | `'v' MEMBER OF (attributes)`                                     | `attributes->'tags' @> '["v"]'`                            | Comparable, MariaDB possibly faster: one B-tree probe and a PK fetch, no bitmap, no recheck. |
| R2 | Common value                      | as R1, `skewed`, top-10 values                                   | as R1                                                      | PostgreSQL faster: it reads rows in physical order; MariaDB does one random `rnd_pos()` per row. Gap grows with matches. |
| R3 | AND of values, rare together      | `JSON_CONTAINS(attributes, '["a","b"]')`                         | `attributes->'tags' @> '["a","b"]'`                        | PostgreSQL faster: it intersects posting lists; MariaDB scans the cheaper value's rows and rechecks each. |
| R4 | OR of many values                 | `JSON_OVERLAPS(attributes, '[...20 values...]')`                 | OR of `@>`, or `?|` with `jsonb_ops`                        | Close for small lists; with many values MariaDB's estimate is capped by `eq_range_index_dive_limit`, PostgreSQL ORs bitmaps. |
| R5 | Combined with another column      | `... AND created BETWEEN ...`                                    | same                                                       | Plan choice: MariaDB's real counts should pick the right index more often; PostgreSQL can combine both with BitmapAnd. Measure plan and time. |
| R6 | Join on membership                | `SELECT ... FROM vals JOIN t ON vals.v MEMBER OF (t.attributes)` | `... ON t.attributes->'tags' @> jsonb_build_array(vals.v)` | PostgreSQL faster: parameterized bitmap scans; MariaDB has no `ref` access through the ARRAY key. |
| R7 | `COUNT(*)` of matches             | `SELECT COUNT(*) ... WHERE <R1/R2>`                              | same                                                       | Neither can count from the index alone; same pattern as R1/R2. |
| R8 | `LIMIT` with `ORDER BY id`        | `... WHERE <R2> ORDER BY id LIMIT 10`                            | same                                                       | Both must read all matches, or scan by PK and filter. Shows which planner picks better. |
| R9 | Number equality                   | `5 MEMBER OF (attributes)`, `numbers`                            | `@> '[5]'`                                                 | Speed similar; check results match. MariaDB misses `-0` and near-zero values (finding #6). |

R1-R9 also run with `pg_array` (`tags @> ARRAY['v']`, `tags && ARRAY[...]`).

## Write workloads

| #  | Workload                              | Statement (MariaDB / PostgreSQL)                                                     | Expectation and reasoning |
|----|---------------------------------------|---------------------------------------------------------------------------------------|---------------------------|
| W1 | Bulk load, index present              | multi-row `INSERT` of all rows (as `prepare`)                                         | PostgreSQL with `fastupdate` faster per row; MariaDB writes one side-table row per element during the statement. Report rows/s. |
| W2 | Index build on loaded table           | `ALTER TABLE ... ADD INDEX` / `CREATE INDEX`                                          | Measures bulk index creation; PostgreSQL sorts keys; MariaDB fills the side table row by row. |
| W3 | Single-row inserts, concurrent        | `INSERT ... VALUES (...)`                                                             | PostgreSQL faster until the pending list is merged, then periodic stalls. Report latency percentiles, not only TPS. |
| W4 | Update the array                      | `UPDATE t SET attributes = ... WHERE id = ?` (replace 1 of the tags)                  | MariaDB: delete and insert all of the row's entries. PostgreSQL: a new row version with all its GIN entries, old ones left for vacuum. |
| W5 | Update another column                 | `UPDATE t SET payload = ... WHERE id = ?`                                             | MariaDB should skip the side table (`update_needed`); PostgreSQL may use a HOT update if no indexed column changes. Both should be cheap; checks that neither touches the array index. |
| W6 | Delete                                | `DELETE FROM t WHERE id = ?`                                                          | MariaDB deletes the entries at once; PostgreSQL leaves them for vacuum. |
| W7 | Upsert                                | `INSERT ... ON DUPLICATE KEY UPDATE` / `INSERT ... ON CONFLICT DO UPDATE`              | Same as W4 when the array changes. Also covers REPLACE on MariaDB (finding #4). |
| W8 | Large arrays                          | W1, W3, W4 with `long`                                                                | Write cost grows with array length on both; compare the slope. |

## Mixed workloads

| #  | Workload                | Mix                                    | What to look for |
|----|-------------------------|----------------------------------------|------------------|
| M1 | Read-mostly             | 95% R1, 5% W4                          | Read latency stays stable on both. |
| M2 | Write-heavy             | 50% R1, 50% W3/W4                      | PostgreSQL pending-list growth and merges as read-latency spikes; MariaDB lock contention on the side table. |
| M3 | Long run with churn     | M2 for 1 hour                          | Index bloat and vacuum on PostgreSQL; side-table growth on MariaDB; throughput over time. |

## Space

After W1, after W4 for 10% of rows, and after M3:

- MariaDB: size of the table, the B-tree indexes and the hlindex side table
  (file sizes, or `information_schema.TABLES` for the side table if listed).
- PostgreSQL: `pg_relation_size()` of the table and each index, and the
  pending list (`gin_metapage_info()` from `pageinspect`).

Expectation: GIN posting lists are compact for common values; MariaDB stores
one B-tree row per element, including the row reference, so it should be
larger, more so with `skewed` data.

## Correctness checks

The benchmark compares speed only if results agree:

- For each read workload, run a fixed set of 100 values on every server and
  compare the matched ids (or counts). Any difference is a bug report, not a
  benchmark result.
- Run the same queries with the index disabled (`IGNORE INDEX` /
  `SET enable_bitmapscan = off` and `enable_indexscan = off`) to check each
  server against itself.
- Print `EXPLAIN` for one instance of every query before its run (as the
  `explain` command does now) and keep it with the results.

## Metrics

- Throughput (TPS) and latency percentiles (p50, p95, p99) from sysbench
  (`--percentile=99`, `--histogram`).
- For writes: rows/s, and latency over time (`--report-interval=1`) to see
  stalls.
- Index and table sizes (Space).
- The plan for every query.

## Known MariaDB limitations to account for

- One hlindex per table: R5 and the variants must not need a second
  multi-valued index on the same table.
- Inserting NULL into the indexed column fails (open on PR 5841): data sets
  must not contain NULL arrays.
- Values that aren't arrays of scalars are rejected; with `INSERT IGNORE` the
  row is kept without index entries (finding #5). Don't use `INSERT IGNORE`.
- Number equality (finding #6) affects R9 results; keep R9 out of speed
  comparisons until it's fixed.
- MariaDB needs the array as the column itself; PostgreSQL indexes
  `attributes->'tags'`. The data is the same; only the layout differs.

## Implementation in `mvi_test.lua`

- `--data-set=uniform|skewed|long|strings|numbers` for `prepare`, with a
  fixed `--rand-seed`.
- `--query-type` gains `common`, `and2`, `or20`, `with_range`, `join`,
  `count`, `limit`, `number` (R2-R9).
- `--write-type=insert|update_array|update_other|delete|upsert` (W3-W7)
  as separate events; W1 is `prepare`, W2 a separate `index` command.
- `--mix=read_mostly|write_heavy` (M1, M2), choosing the event per
  transaction.
- A `payload` column (not indexed) for W5, and a `created` column with a
  B-tree index for R5.
- `pg_array` as another `--index-type`.
- A `verify` command that prints the matched ids for the fixed value set.
