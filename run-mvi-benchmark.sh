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
    --mysql-host=127.0.0.1
    --mysql-port=3319
    --mysql-user=root
    --mysql-db=test
    --rand-type=uniform
    --index-type=mariadb_array
  )

else
  echo "Need argument: mysql, mariadb_ft_json or mariadb"
  exit 1
fi


TABLE_SIZES=(10000 50000 100000 500000 1000000)
TEST_NAME=mvi_test.lua

RESULT_NAME=res4
THREADS=32

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
    OUTPUT=$(sysbench $TEST_NAME "${SYSBENCH_COMMON_ARGS[@]}" --query-type=$QUERY_TYPE --table-size=$SIZE --time=30 --threads=$THREADS run)

    # 2.1. Parse TPS and QPS from output
    TPS=$(echo "$OUTPUT" | awk -F'(' '/transactions:/ {print $2}' | awk '{print $1}')
    #QPS=$(echo "$OUTPUT" | awk -F'(' '/queries:/ {print $2}' | awk '{print $1}')

    echo "Result($QUERY_TYPE) -> Table Size: $SIZE | TPS: $TPS | QPS: $QPS"

    # 2.3. Append to CSV
    echo "$SIZE,$TPS" >> $LOG_FILE-$QUERY_TYPE.csv

  done
done

sysbench $TEST_NAME "${SYSBENCH_COMMON_ARGS[@]}" cleanup
