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
  echo "Usage: $0 (mysql|mariadb_ft_json|mariadb|pg) [THREADS] [CPUS]"
  exit 1
fi


TABLE_SIZES=(10000 50000 100000 500000 1000000)
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

LOG_FILE="$RESULT_NAME-$SERVER-thr-$THREADS"

# Output CSV headers
echo "table_size,tps" > $LOG_FILE-attr1.csv
echo "table_size,tps" > $LOG_FILE-member.csv

for SIZE in "${TABLE_SIZES[@]}"; do
  echo "=== Testing Table Size: $SIZE ==="

  # 1. Cleanup old data & Prepare new test table
  sysbench $TEST_NAME "${SYSBENCH_COMMON_ARGS[@]}" cleanup
  sysbench $TEST_NAME "${SYSBENCH_COMMON_ARGS[@]}" --table-size=$SIZE prepare

  for QUERY_TYPE in attr1 member ; do

    sysbench \
        $TEST_NAME "${SYSBENCH_COMMON_ARGS[@]}" \
	--query-type=$QUERY_TYPE --table-size=$SIZE \
	explain

    # 2. Run workload and capture output
    OUTPUT=$("${PIN[@]}" sysbench $TEST_NAME "${SYSBENCH_COMMON_ARGS[@]}" --query-type=$QUERY_TYPE --table-size=$SIZE --time=30 --threads=$THREADS run)

    # 2.1. Parse TPS and QPS from output
    TPS=$(echo "$OUTPUT" | awk -F'(' '/transactions:/ {print $2}' | awk '{print $1}')
    #QPS=$(echo "$OUTPUT" | awk -F'(' '/queries:/ {print $2}' | awk '{print $1}')

    echo "Result($QUERY_TYPE) -> Table Size: $SIZE | TPS: $TPS | QPS: $QPS"

    # 2.3. Append to CSV
    echo "$SIZE,$TPS" >> $LOG_FILE-$QUERY_TYPE.csv

  done
done

sysbench $TEST_NAME "${SYSBENCH_COMMON_ARGS[@]}" cleanup
