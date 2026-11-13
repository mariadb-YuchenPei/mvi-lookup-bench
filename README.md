
Multi Value Index Lookup benchmark for https://jira.mariadb.org/browse/MDEV-40168

It tests

* MySQL: Multi-Value Index
* MariaDB: Emulation of multi-value index through Fulltext.
* MariaDB: Multi-Value Index (MDEV-25848)
* PostgreSQL: GIN index on the JSONB tags array

Usage:
```
  run-mvi-benchmark.sh  (mysql|mariadb_ft_json|mariadb|pg) [THREADS] [CPUS]
```

* `THREADS`: number of sysbench client threads, default 32.
* `CPUS`: CPUs to pin the sysbench client to during the run, in
  `taskset -c` format (for example `8-15`). Default: no pinning. Pin the
  server separately, for example `taskset -c 0-7 mariadbd ...`.

For example, 8 client threads pinned to CPUs 8-15:
```
  run-mvi-benchmark.sh mariadb 8 8-15
```
