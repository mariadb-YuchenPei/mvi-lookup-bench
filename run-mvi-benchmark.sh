#!/usr/bin/env bash

if [[ "$1" == "mysql" ]]; then

  SERVER=mysql
  SYSBENCH_COMMON_ARGS=(
    --mysql-host=127.0.0.1
    --mysql-port=3312
    --mysql-user=root
    --mysql-db=test
    --rand-type=uniform
    --index-type=array
  )

elif [[ "$1" == "mariadb_ft_json" ]]; then

  SERVER=mariadb
  SYSBENCH_COMMON_ARGS=(
    --mysql-host=127.0.0.1
    --mysql-port=3319
    --mysql-user=root
    --mysql-db=test
    --rand-type=uniform
    --index-type=ft_json
  )

elif [[ "$1" == "mariadb" ]]; then

  SERVER=mariadb_mvi
  SYSBENCH_COMMON_ARGS=(
    --mysql-socket=/tmp/build.sock
    --mysql-user=$USER
    --mysql-db=test
    --rand-type=uniform
    --index-type=mariadb_array
  )

elif [[ "$1" == "pg" ]]; then

  # --pgsql-host may also be a socket directory, e.g. /tmp
  SERVER=pgsql
  SYSBENCH_COMMON_ARGS=(
    --db-driver=pgsql
    --pgsql-host=127.0.0.1
    --pgsql-port=5432
    --pgsql-user=$USER
    --pgsql-db=test
    --rand-type=uniform
    --index-type=pg_gin
  )

else
  echo "Usage: $0 (mysql|mariadb_ft_json|mariadb|pg) [THREADS] [CPUS] [SUITE]"
  exit 1
fi


TEST_NAME=mvi_test.lua

RESULT_NAME=res4
# Number of sysbench client threads (default 32)
THREADS=${2:-32}

# CPU list for the sysbench client during the run, in taskset -c format
# (e.g. 8-15). Default: no pinning. Pin the server separately.
CPUS=${3:-}
PIN=()
if [[ -n "$CPUS" ]]; then
  PIN=(taskset -c "$CPUS")
fi

# Workloads to run (see mariadb-vs-pg.md):
# - r1 (default): R1 and its control on the uniform data set;
# - p1: the priority 1 workloads R3, R5 and R6, each with its controls, on
#   the skewed data set. Each server loads the same data (fixed seed).
SUITE=${4:-r1}
if [[ "$SUITE" == "r1" ]]; then
  DEFAULT_TABLE_SIZES="10000 50000 100000 500000 1000000"
  DATA_ARGS=()
  SEED_ARGS=()
  QUERY_TYPES=(attr1 member)
elif [[ "$SUITE" == "p1" ]]; then
  DEFAULT_TABLE_SIZES="100000 1000000 10000000"
  # --rand-pareto-h=0.3: roughly 6% of the tags drawn are value-1 and 16%
  # are among the 20 most common (the default 0.2 gives 28% and 42%)
  DATA_ARGS=(--data-set=skewed --rand-pareto-h=0.3)
  SEED_ARGS=(--rand-seed=1)
  QUERY_TYPES=(and2_attr and2 range_only member with_range join_attr1 join)
else
  echo "Unknown SUITE '$SUITE' (expected: r1, p1)"
  exit 1
fi

# Table sizes, overridable, e.g. TABLE_SIZES="100000 1000000"
read -r -a TABLE_SIZES <<< "${TABLE_SIZES:-$DEFAULT_TABLE_SIZES}"

# Seconds of warm-up before each measured run, not counted in the results
WARMUP=${WARMUP:-10}

LOG_FILE="$RESULT_NAME-$SERVER-$SUITE-thr-$THREADS"
if [[ "$SUITE" == "r1" ]]; then
  # Keep the names of the existing R1 results
  LOG_FILE="$RESULT_NAME-$SERVER-thr-$THREADS"
fi

# Output CSV headers
for QUERY_TYPE in "${QUERY_TYPES[@]}"; do
  echo "table_size,tps" > $LOG_FILE-$QUERY_TYPE.csv
done

for SIZE in "${TABLE_SIZES[@]}"; do
  echo "=== Testing Table Size: $SIZE ==="

  # 1. Cleanup old data & Prepare new test table
  sysbench $TEST_NAME "${SYSBENCH_COMMON_ARGS[@]}" cleanup
  sysbench $TEST_NAME "${SYSBENCH_COMMON_ARGS[@]}" "${DATA_ARGS[@]}" "${SEED_ARGS[@]}" --table-size=$SIZE prepare

  for QUERY_TYPE in "${QUERY_TYPES[@]}"; do

    sysbench \
        $TEST_NAME "${SYSBENCH_COMMON_ARGS[@]}" "${DATA_ARGS[@]}" \
	--query-type=$QUERY_TYPE --table-size=$SIZE \
	explain

    # Matched ids of a fixed set of queries: compare these files between
    # servers before trusting the timings
    if [[ "$SUITE" != "r1" ]]; then
      sysbench \
          $TEST_NAME "${SYSBENCH_COMMON_ARGS[@]}" "${DATA_ARGS[@]}" "${SEED_ARGS[@]}" \
          --query-type=$QUERY_TYPE --table-size=$SIZE \
          verify > $LOG_FILE-$QUERY_TYPE-$SIZE.verify
    fi

    # 2. Warm up with the same workload, discarding the results (a separate
    # run, as not every sysbench version has --warmup-time)
    if (( WARMUP > 0 )); then
      "${PIN[@]}" sysbench $TEST_NAME "${SYSBENCH_COMMON_ARGS[@]}" "${DATA_ARGS[@]}" --query-type=$QUERY_TYPE --table-size=$SIZE --time=$WARMUP --threads=$THREADS run > /dev/null
    fi

    # 3. Run workload and capture output
    OUTPUT=$("${PIN[@]}" sysbench $TEST_NAME "${SYSBENCH_COMMON_ARGS[@]}" "${DATA_ARGS[@]}" --query-type=$QUERY_TYPE --table-size=$SIZE --time=30 --threads=$THREADS run)

    # 3.1. Parse TPS and QPS from output
    TPS=$(echo "$OUTPUT" | awk -F'(' '/transactions:/ {print $2}' | awk '{print $1}')
    #QPS=$(echo "$OUTPUT" | awk -F'(' '/queries:/ {print $2}' | awk '{print $1}')

    echo "Result($QUERY_TYPE) -> Table Size: $SIZE | TPS: $TPS | QPS: $QPS"

    # 3.3. Append to CSV
    echo "$SIZE,$TPS" >> $LOG_FILE-$QUERY_TYPE.csv

  done
done

sysbench $TEST_NAME "${SYSBENCH_COMMON_ARGS[@]}" cleanup
