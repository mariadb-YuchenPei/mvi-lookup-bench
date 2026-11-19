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
# - w: the write workloads W1 (load), W2 (index build), W3 (inserts), W4
#   (array updates) and M2 (write-heavy mix) on the skewed data set, with
#   and without the array index.
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
elif [[ "$SUITE" == "w" ]]; then
  DEFAULT_TABLE_SIZES="100000 1000000 10000000"
  DATA_ARGS=(--data-set=skewed --rand-pareto-h=0.3)
  SEED_ARGS=(--rand-seed=1)
  QUERY_TYPES=(insert update_array write_heavy)
else
  echo "Unknown SUITE '$SUITE' (expected: r1, p1, w)"
  exit 1
fi

# Table sizes, overridable, e.g. TABLE_SIZES="100000 1000000"
read -r -a TABLE_SIZES <<< "${TABLE_SIZES:-$DEFAULT_TABLE_SIZES}"

# Seconds of warm-up before each measured run, not counted in the results
WARMUP=${WARMUP:-10}

# PostgreSQL: fastupdate of the GIN index, on (default) or off
GIN_FASTUPDATE=${GIN_FASTUPDATE:-on}

LOG_FILE="$RESULT_NAME-$SERVER-$SUITE-thr-$THREADS"
if [[ "$SUITE" == "r1" ]]; then
  # Keep the names of the existing R1 results
  LOG_FILE="$RESULT_NAME-$SERVER-thr-$THREADS"
fi
if [[ "$GIN_FASTUPDATE" == "off" ]]; then
  LOG_FILE="$LOG_FILE-nofastupdate"
fi
SYSBENCH_COMMON_ARGS+=(--gin-fastupdate=$GIN_FASTUPDATE)

# Seconds elapsed while running the command given as arguments
timed() {
  local start end
  start=$(date +%s.%N)
  "$@" > /dev/null || echo "Failed: $*" >&2
  end=$(date +%s.%N)
  awk -v s="$start" -v e="$end" 'BEGIN { printf "%.2f\n", e - s }'
}

if [[ "$SUITE" == "w" ]]; then
  # Write workloads. For each table size, once with the array index (on)
  # and once without it (off, the control):
  # - W1: load the table (prepare without settling), timed, then settle,
  #   timed separately (PostgreSQL merges the GIN pending list, MariaDB
  #   writes out dirty pages);
  # - W2 (on only): drop and re-create the array index, and the attr1
  #   B-tree as its control, timing the creation;
  # - W3, W4, M2 (M2 on only, as its lookups need the index): TPS and
  #   99th percentile latency, and the TPS of every second in a log file to
  #   show stalls. The writes change the table, so they run in this order
  #   on the same table.
  echo "table_size,load_s,rows_per_s,settle_s" > $LOG_FILE-load-on.csv
  echo "table_size,load_s,rows_per_s,settle_s" > $LOG_FILE-load-off.csv
  echo "table_size,array_s,attr1_s" > $LOG_FILE-index.csv
  for QUERY_TYPE in "${QUERY_TYPES[@]}"; do
    echo "table_size,tps,p99_ms" > $LOG_FILE-$QUERY_TYPE-on.csv
    echo "table_size,tps,p99_ms" > $LOG_FILE-$QUERY_TYPE-off.csv
  done
  rm -f $LOG_FILE-write_heavy-off.csv

  for SIZE in "${TABLE_SIZES[@]}"; do
    for VARIANT in on off; do
      echo "=== Table Size: $SIZE, array index: $VARIANT ==="
      # --join-groups=0: no join tags (mvi_vals) to load, which would count
      # towards the load time
      ARGS=("${SYSBENCH_COMMON_ARGS[@]}" "${DATA_ARGS[@]}" --table-size=$SIZE --array-index=$VARIANT --join-groups=0)

      sysbench $TEST_NAME "${SYSBENCH_COMMON_ARGS[@]}" cleanup > /dev/null
      LOAD_S=$(timed sysbench $TEST_NAME "${ARGS[@]}" "${SEED_ARGS[@]}" --settle=off prepare)
      SETTLE_S=$(timed sysbench $TEST_NAME "${ARGS[@]}" settle)
      ROWS_PER_S=$(awk -v n=$SIZE -v t=$LOAD_S 'BEGIN { printf "%.0f\n", n / t }')
      echo "W1 -> load: $LOAD_S s ($ROWS_PER_S rows/s), settle: $SETTLE_S s"
      echo "$SIZE,$LOAD_S,$ROWS_PER_S,$SETTLE_S" >> $LOG_FILE-load-$VARIANT.csv

      TYPES=("${QUERY_TYPES[@]}")
      if [[ "$VARIANT" == "on" ]]; then
        INDEX_S=()
        for INDEX in array attr1; do
          sysbench $TEST_NAME "${ARGS[@]}" --index-name=$INDEX drop_index > /dev/null
          INDEX_S+=($(timed sysbench $TEST_NAME "${ARGS[@]}" --index-name=$INDEX create_index))
        done
        echo "W2 -> array index: ${INDEX_S[0]} s, attr1 index: ${INDEX_S[1]} s"
        echo "$SIZE,${INDEX_S[0]},${INDEX_S[1]}" >> $LOG_FILE-index.csv
        sysbench $TEST_NAME "${ARGS[@]}" settle > /dev/null
      else
        TYPES=(insert update_array)
      fi

      for QUERY_TYPE in "${TYPES[@]}"; do
        if (( WARMUP > 0 )); then
          "${PIN[@]}" sysbench $TEST_NAME "${ARGS[@]}" --query-type=$QUERY_TYPE --time=$WARMUP --threads=$THREADS run > /dev/null
        fi
        RUN_LOG="$LOG_FILE-$QUERY_TYPE-$VARIANT-$SIZE.log"
        "${PIN[@]}" sysbench $TEST_NAME "${ARGS[@]}" --query-type=$QUERY_TYPE --time=30 --threads=$THREADS --percentile=99 --report-interval=1 run > "$RUN_LOG"
        TPS=$(awk -F'(' '/transactions:/ {print $2}' "$RUN_LOG" | awk '{print $1}')
        P99=$(awk '/99th percentile:/ {print $NF}' "$RUN_LOG")
        echo "Result($QUERY_TYPE, $VARIANT) -> Table Size: $SIZE | TPS: $TPS | p99: $P99 ms"
        echo "$SIZE,$TPS,$P99" >> $LOG_FILE-$QUERY_TYPE-$VARIANT.csv
      done
    done
  done

  sysbench $TEST_NAME "${SYSBENCH_COMMON_ARGS[@]}" cleanup
  exit 0
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
