#!/usr/bin/env bash
######################################################
# Author  : Mohammed Ali
# Version : 4.0.2
# Purpose : dbaascli database precheck, then create database
######################################################

clear
set -euo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
SCRIPT_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

INI_FILE="${INI_FILE:-$SCRIPT_HOME/config/migration_db.ini}"
FILTER_DB="${FILTER_DB:-}"

WAIT_FOR_COMPLETION="${WAIT_FOR_COMPLETION:-true}"
TDE_CONFIG_METHOD="${TDE_CONFIG_METHOD:-FILE}"
FRA_SIZE_MB="${FRA_SIZE_MB:-204800}"
DEFAULT_ORACLE_HOME="${ORACLE_HOME:-/u02/app/oracle/product/19.0.0.0/dbhome_1}"

LOG_DIR="${LOG_DIR:-$SCRIPT_HOME/logs}"
mkdir -p "$LOG_DIR"

RUN_MODE=""

usage() {
cat <<EOF
Usage:
  $SCRIPT_NAME -p [-d dbName]
  $SCRIPT_NAME -s [-d dbName]

Options:
  -p              Run PRIMARY database precheck + create
  -s              Run STANDBY database precheck + create
  -d <dbName>     Run for one database only
  -i <ini_file>   INI file path
  -h              Help

Examples:
  $SCRIPT_NAME -p
  $SCRIPT_NAME -s
  $SCRIPT_NAME -p -d txndcq01
  $SCRIPT_NAME -s -d txndcq01
EOF
}

while getopts ":psd:i:h" opt; do
  case "$opt" in
    p) RUN_MODE="PRIMARY" ;;
    s) RUN_MODE="STANDBY" ;;
    d) FILTER_DB="$OPTARG" ;;
    i) INI_FILE="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

if [[ -z "$RUN_MODE" ]]; then
  echo "ERROR: Please provide either -p for PRIMARY or -s for STANDBY."
  usage
  exit 1
fi

RUN_TS="$(date +%Y%m%d_%H%M%S)"
MASTER_LOG="$LOG_DIR/odaa_db_create_${RUN_MODE}_${RUN_TS}.log"
SUMMARY_FILE="$LOG_DIR/db_create_summary_${RUN_MODE}_${RUN_TS}.txt"

exec > >(tee -a "$MASTER_LOG") 2>&1

echo " "
echo "                      DATABASE CREATE SUMMARY            " | tee "$SUMMARY_FILE"
echo "____________________________________________________________________________________________"
echo "Script      : $SCRIPT_NAME"
echo "Purpose     : dbaascli database create precheck & create database"
echo "Author      : Mohammed Ali"
echo "Version     : 4.0.2"
echo "Mode        : $RUN_MODE PRECHECK + DATABASE CREATE"
echo "INI         : $INI_FILE"
echo "DB          : ${FILTER_DB:-ALL}"
echo "Oracle Home : $DEFAULT_ORACLE_HOME"
echo "Start       : $(date)"
echo "Master Log  : $MASTER_LOG"
echo "Summary Log : $SUMMARY_FILE"
echo "____________________________________________________________________________________________"

command -v /usr/bin/dbaascli >/dev/null || {
  echo "ERROR: dbaascli not found under /usr/bin/dbaascli"
  exit 1
}

[[ -f "$INI_FILE" ]] || {
  echo "ERROR: INI file not found: $INI_FILE"
  exit 1
}

chmod 600 "$INI_FILE" || true

db_exists() {
  local dbName="$1"

  sudo /usr/bin/dbaascli database list 2>/dev/null | \
    awk -F= '/DB Name/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' | \
    grep -Eixq "$dbName"
}

run_dbaas_create() {
  local execute_prereqs="$1"
  local log_file="$2"

  {
    printf '%s\n' "$syspass"
    printf '%s\n' "$syspass"
    [[ -n "${tdepass:-}" ]] && printf '%s\n%s\n' "$tdepass" "$tdepass"
  } | sudo /usr/bin/dbaascli database create \
      --dbName "$TARGET_DB_NAME" \
      --oracleHome "$TARGET_ORACLE_HOME" \
      --dbUniqueName "$TARGET_DB_UNIQUE_NAME" \
      --dbSID "$TARGET_DB_SID" \
      --createAsCDB "$enableCDB" \
      --dbCharset "$dbCharset" \
      --dbNCharset "$dbNCharset" \
      --datafileDestination "$TARGET_DATA_DEST" \
      --fraDestination "$TARGET_FRA_DEST" \
      --fraSizeInMB "$FRA_SIZE_MB" \
      --nodeList "$TARGET_NODE_LIST" \
      --tdeConfigMethod "$TDE_CONFIG_METHOD" \
      --dbBlockSizeInKB "$dbBlockSizeInKB" \
      --waitForCompletion "$WAIT_FOR_COMPLETION" \
      $execute_prereqs > "$log_file" 2>&1
}

tail -n +2 "$INI_FILE" | while IFS='|' read -r \
  dbName dbUniqueName dbSID dbCharset dbNCharset \
  pdatafileDestination pfraDestination pNodeList port syspass tdepass \
  primaryScanIPAddresses primaryScanPort pServiceName \
  standbyScanIPAddresses standbyScanPort sServiceName standbyDBUniqueName \
  sdatafileDestination sfraDestination sNodeList flagSkip \
  dbBlockSizeInKB enableCDB dbHome
do

  [[ -z "${dbName// }" ]] && continue

  if [[ -n "$FILTER_DB" && "$dbName" != "$FILTER_DB" ]]; then
    continue
  fi

  flagSkip="$(echo "${flagSkip:-N}" | tr '[:lower:]' '[:upper:]' | xargs)"

  if [[ "$flagSkip" == "Y" ]]; then
    echo "⚠️  $dbName : SKIPPED (flagSkip=Y) CHECK $INI_FILE" | tee -a "$SUMMARY_FILE"
    continue
  fi

  if [[ "$RUN_MODE" == "PRIMARY" ]]; then
    TARGET_DB_NAME="$dbName"
    TARGET_DB_UNIQUE_NAME="$dbUniqueName"
    TARGET_DB_SID="$dbSID"
    TARGET_DATA_DEST="$pdatafileDestination"
    TARGET_FRA_DEST="$pfraDestination"
    TARGET_NODE_LIST="$pNodeList"
  else
    TARGET_DB_NAME="$dbName"
    TARGET_DB_UNIQUE_NAME="$standbyDBUniqueName"
    TARGET_DB_SID="$dbSID"
    TARGET_DATA_DEST="$sdatafileDestination"
    TARGET_FRA_DEST="$sfraDestination"
    TARGET_NODE_LIST="$sNodeList"
  fi

  TARGET_ORACLE_HOME="${dbHome:-$DEFAULT_ORACLE_HOME}"

  PRECHECK_LOG="$LOG_DIR/${TARGET_DB_UNIQUE_NAME}_precheck_${RUN_TS}.log"
  CREATE_LOG="$LOG_DIR/${TARGET_DB_UNIQUE_NAME}_create_${RUN_TS}.log"

  if db_exists "$TARGET_DB_NAME"; then
    echo "⚠️  $TARGET_DB_NAME : ALREADY EXISTS → PRECHECK/CREATE SKIPPED" | tee -a "$SUMMARY_FILE"
    continue
  fi

  if [[ -z "${TARGET_DB_UNIQUE_NAME// }" || -z "${TARGET_DATA_DEST// }" || -z "${TARGET_FRA_DEST// }" || -z "${TARGET_NODE_LIST// }" ]]; then
    echo "❌ $dbName : Missing required $RUN_MODE values in INI file" | tee -a "$SUMMARY_FILE"
    continue
  fi

  echo
  echo "Processing DB      : $dbName"
  echo "Run Mode           : $RUN_MODE"
  echo "Target DB Name     : $TARGET_DB_NAME"
  echo "Target Unique Name : $TARGET_DB_UNIQUE_NAME"
  echo "Target Node List   : $TARGET_NODE_LIST"
  echo "Target Data Dest   : $TARGET_DATA_DEST"
  echo "Target FRA Dest    : $TARGET_FRA_DEST"
  echo "Oracle Home        : $TARGET_ORACLE_HOME"

  echo "Running PRECHECK for DB: $TARGET_DB_UNIQUE_NAME"

  set +e
  run_dbaas_create "--executePrereqs" "$PRECHECK_LOG"
  PRECHECK_RC=$?
  set -e

  if [[ "$PRECHECK_RC" -eq 0 ]] && grep -Eqi "success|successfully|passed|completed|prereq" "$PRECHECK_LOG"; then
    echo "✅ $TARGET_DB_UNIQUE_NAME : PRECHECK PASS" | tee -a "$SUMMARY_FILE"
    echo "   PRECHECK LOG: $PRECHECK_LOG" | tee -a "$SUMMARY_FILE"

    echo "Running CREATE for DB: $TARGET_DB_UNIQUE_NAME"

    set +e
    run_dbaas_create "" "$CREATE_LOG"
    CREATE_RC=$?
    set -e

    if [[ "$CREATE_RC" -eq 0 ]] && grep -Eqi "success|successfully|completed|created" "$CREATE_LOG"; then
      echo "🚀 $TARGET_DB_UNIQUE_NAME : CREATE SUCCESS" | tee -a "$SUMMARY_FILE"
    else
      echo "❌ $TARGET_DB_UNIQUE_NAME : CREATE FAILED" | tee -a "$SUMMARY_FILE"
      echo "   Reason:" | tee -a "$SUMMARY_FILE"
      grep -Eai "error|failed|fail|exception|ORA-|PRCD-|PRCR-|CRS-|DCS-|DBT-|No input provided|FATAL" "$CREATE_LOG" | tail -30 | tee -a "$SUMMARY_FILE" || true
    fi

    echo "   CREATE LOG: $CREATE_LOG" | tee -a "$SUMMARY_FILE"

  else
    echo "❌ $TARGET_DB_UNIQUE_NAME : PRECHECK FAILED → CREATE SKIPPED" | tee -a "$SUMMARY_FILE"
    echo "   Reason:" | tee -a "$SUMMARY_FILE"
    grep -Eai "error|failed|fail|exception|ORA-|PRCD-|PRCR-|CRS-|DCS-|DBT-|No input provided|FATAL" "$PRECHECK_LOG" | tail -30 | tee -a "$SUMMARY_FILE" || true
    echo "   PRECHECK LOG: $PRECHECK_LOG" | tee -a "$SUMMARY_FILE"
  fi

done

echo " "
echo "List all Database's with Database Role"
echo "____________________________________________________________________________________________"

sudo /usr/bin/dbaascli system getDatabases | awk -F'"' '
BEGIN {
  printf "%-5s %-12s %-20s %-20s\n", "SEQ", "DB_NAME", "DB_UNIQUE_NAME", "DB_ROLE"
}
/"dbName"/ {name=$4}
/"dbUniqueName"/ {uniq=$4}
/"dbRole"/ {
  role=$4
  seq++
  printf "%-5s %-12s %-20s %-20s\n", seq, name, uniq, role
}'

echo
echo "____________________________________________________________________________________________"
echo "Completed : $(date)"
echo "Master Log: $MASTER_LOG"
echo "Summary   : $SUMMARY_FILE"
echo "____________________________________________________________________________________________"

