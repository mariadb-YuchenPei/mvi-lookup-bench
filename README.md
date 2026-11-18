
Multi Value Index Lookup benchmark for https://jira.mariadb.org/browse/MDEV-40168

It tests

* MySQL: Multi-Value Index
* MariaDB: Emulation of multi-value index through Fulltext.
* MariaDB: Multi-Value Index (MDEV-25848)
* PostgreSQL: GIN index on the JSONB tags array

Usage:
```
  run-mvi-benchmark.sh  (mysql|mariadb_ft_json|mariadb|pg) [THREADS] [CPUS] [SUITE]
```

* `THREADS`: number of sysbench client threads, default 32.
* `CPUS`: CPUs to pin the sysbench client to during the run, in
  `taskset -c` format (for example `8-15`). Default: no pinning. Pin the
  server separately, for example `taskset -c 0-7 mariadbd ...`.

* `SUITE`: the workloads to run, see `mariadb-vs-pg.md`:
  * `r1` (default): single-tag lookup (R1) and its `attr1` control on the
    uniform data set, at 10k to 1M rows.
  * `p1`: the priority 1 workloads on the skewed data set, at 100k, 1M and
    10M rows, each with its controls: AND of two common tags (R3,
    `and2` / `and2_attr`), one tag with a range on another column (R5,
    `with_range` / `member` / `range_only`) and a join on membership (R6,
    `join` / `join_attr1`). Supported by `mariadb`, `pg` and `mysql`.
    Each query type also writes a `.verify` file with the ids matched by a
    fixed set of queries; compare them between servers before comparing
    timings.

  Set `TABLE_SIZES` to override the table sizes, for example
  `TABLE_SIZES="100000 1000000"`.

Each run is preceded by a warm-up of `WARMUP` seconds (default 10), not
counted in the results, for example `WARMUP=30 run-mvi-benchmark.sh pg`.

For example, 8 client threads pinned to CPUs 8-15:
```
  run-mvi-benchmark.sh mariadb 8 8-15
```
