#!/usr/bin/env bash

#############################################################
# Author  : Mohammed Ali
# Version : 4.9.0
# Purpose : Data Guard Status Validation from migration_db.ini
#############################################################
clear
echo
echo "                                                            DATABASE STATUS HEALTH CHECK REPORT   "
printf '%0.s_' {1..160}
echo
echo "Script      : odaa_db_status_health.sh"
echo "Purpose     : Database's Health Check"
echo "Author      : Mohammed Ali"
echo "Version     : 4.0.6"
echo "Mode        : DATABASE STATUS HEALTH CHECK ONLY "
echo "Start       : $(date)"
printf '%0.s_' {1..160}
echo 
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
SCRIPT_HOME="${SCRIPT_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

INI_FILE="${INI_FILE:-$SCRIPT_HOME/config/migration_db.ini}"
LOG_DIR="${LOG_DIR:-$SCRIPT_HOME/logs}"
DB_FILTER="${DB_FILTER:-}"

SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
SCRIPT_HOME="${SCRIPT_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

INI_FILE="${INI_FILE:-$SCRIPT_HOME/config/migration_db.ini}"
LOG_DIR="${LOG_DIR:-$SCRIPT_HOME/logs}"

if [[ "$(id -un)" != "oracle" ]]; then
  echo "Re-launching as oracle..."
  exec sudo -iu oracle env \
    SCRIPT_HOME="$SCRIPT_HOME" \
    INI_FILE="$INI_FILE" \
    LOG_DIR="$LOG_DIR" \
    "$SCRIPT_PATH" "$@"
fi


usage() {
cat <<EOF

Usage:
  $(basename "$0") --all
  $(basename "$0") -d <db_name>
  $(basename "$0") -d <db1,db2,...>
  $(basename "$0") -h

Options:
  --all               Process all databases
  -d, --database      One or more databases separated by commas
  -h, --help          Display help

Examples:
  $(basename "$0") --all
  $(basename "$0") -d MCK
  $(basename "$0") -d MCK16
  $(basename "$0") -d MCK,POC

EOF
exit 1
}

if [[ -z "$DB_FILTER" ]]; then
  [[ $# -eq 0 ]] && usage

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all)
        DB_FILTER="ALL"
        shift
        ;;
      -d|--database)
        [[ -z "${2:-}" ]] && usage
        DB_FILTER="$2"
        shift 2
        ;;
      -h|--help)
        usage
        ;;
      *)
        echo "ERROR: Invalid option '$1'"
        usage
        ;;
    esac
  done
fi

if [[ "$(id -un)" != "oracle" ]]; then
  echo "Re-launching as oracle..."
  exec sudo -iu oracle env \
    SCRIPT_HOME="$SCRIPT_HOME" \
    INI_FILE="$INI_FILE" \
    LOG_DIR="$LOG_DIR" \
    DB_FILTER="$DB_FILTER" \
    "$0"
fi


mkdir -p "$LOG_DIR"

RUN_TS="$(date +%Y%m%d_%H%M%S)"
SUMMARY_FILE="$LOG_DIR/dg_status_summary_${RUN_TS}.txt"

if [[ ! -r "$INI_FILE" ]]; then
  echo "ERROR: oracle user cannot read INI file: $INI_FILE"
  exit 1
fi

is_selected_db() {
  local current_db="$1"

  [[ "$DB_FILTER" == "ALL" ]] && return 0

  IFS=',' read -ra DBS <<< "$DB_FILTER"

  for db in "${DBS[@]}"; do
    db="$(echo "$db" | sed 's/^ *//;s/ *$//')"
    [[ "$current_db" == "$db" ]] && return 0
  done

  return 1
}

get_running_instances() {
  local db_home="$1"
  local oracle_sid="$2"

  ORACLE_HOME="$db_home" ORACLE_SID="$oracle_sid" \
  "$db_home/bin/sqlplus" -s / as sysdba <<EOF 2>/dev/null | sed '/^$/d' | paste -sd "," -
set pages 0 feedback off heading off verify off echo off
select instance_name
from gv\$instance
order by inst_id;
exit;
EOF
}

SUCCESS_CNT=0
WARNING_CNT=0
READY_CNT=0
NOT_READY_CNT=0
seq=0

{
echo
echo "Database Selection : $DB_FILTER"
echo
printf "%-4s %-10s %-18s %-25s %-18s %-25s %-18s %-12s %-12s %-10s\n" \
"SEQ" "DB_NAME" "PRIMARY_DB" "PRIMARY_INSTANCES" "STANDBY_DB" "STANDBY_INSTANCES" "STBY_ROLE" "APPLY_LAG" "DG_STATUS" "READY"
printf '%0.s_' {1..160}
echo
} | tee "$SUMMARY_FILE"

while IFS='|' read -r \
dbName dbUniqueName dbSID dbCharset dbNCharset pdatafileDestination pfraDestination pNodeList port syspass tdepass \
primaryScanIPAddresses primaryScanPort pServiceName standbyScanIPAddresses standbyScanPort sServiceName standbyDBUniqueName \
sdatafileDestination sfraDestination sNodeList flagSkip dbBlockSizeInKB enableCDB dbHome
do
  dbName="$(echo "${dbName:-}" | tr -d '\r' | sed 's/^ *//;s/ *$//')"
  dbUniqueName="$(echo "${dbUniqueName:-}" | tr -d '\r' | sed 's/^ *//;s/ *$//')"
  dbSID="$(echo "${dbSID:-}" | tr -d '\r' | sed 's/^ *//;s/ *$//')"
  standbyDBUniqueName="$(echo "${standbyDBUniqueName:-}" | tr -d '\r' | sed 's/^ *//;s/ *$//')"
  flagSkip="$(echo "${flagSkip:-N}" | tr -d '\r' | sed 's/^ *//;s/ *$//')"
  dbHome="$(echo "${dbHome:-}" | tr -d '\r' | sed 's/^ *//;s/ *$//')"

  [[ -z "$dbName" ]] && continue
  [[ "$flagSkip" == "Y" ]] && continue
  is_selected_db "$dbName" || continue

  if [[ -z "$dbHome" || ! -x "$dbHome/bin/sqlplus" || ! -x "$dbHome/bin/dgmgrl" ]]; then
    echo "WARNING: Skipping $dbName - invalid dbHome: $dbHome" | tee -a "$SUMMARY_FILE"
    ((++WARNING_CNT))
    continue
  fi

  export ORACLE_HOME="$dbHome"
  export PATH="$ORACLE_HOME/bin:$PATH"
  export ORACLE_SID="${dbSID}1"

  PRIMARY_INSTANCES="$(get_running_instances "$dbHome" "$ORACLE_SID" || true)"
  [[ -z "$PRIMARY_INSTANCES" ]] && PRIMARY_INSTANCES="UNKNOWN"

  DGOUT="$("$ORACLE_HOME/bin/dgmgrl" -silent / <<EOF 2>/dev/null || true
show configuration;
show database verbose '$standbyDBUniqueName';
validate database '$standbyDBUniqueName';
exit;
EOF
)"

  STBY_ROLE="$(echo "$DGOUT" | grep -i "^  Role:" | awk -F':' '{print $2}' | sed 's/^ *//;s/ *$//' | head -1 || true)"
  APPLY_LAG="$(echo "$DGOUT" | awk -F':' '/Apply Lag/ {print $2; exit}' | sed 's/(.*//;s/^ *//;s/ *$//' || true)"

  [[ -z "$STBY_ROLE" ]] && STBY_ROLE="UNKNOWN"
  [[ -z "$APPLY_LAG" ]] && APPLY_LAG="UNKNOWN"

  if echo "$DGOUT" | grep -qi "SUCCESS"; then
    DG_STATUS="SUCCESS"
    ((++SUCCESS_CNT))
  else
    DG_STATUS="WARNING"
    ((++WARNING_CNT))
  fi

  if echo "$DGOUT" | grep -qi "Ready for Switchover"; then
    READY="YES"
    ((++READY_CNT))
  else
    READY="NO"
    ((++NOT_READY_CNT))
  fi

  STANDBY_INSTANCES="${standbyDBUniqueName}1,${standbyDBUniqueName}2"

  ((++seq))

  printf "%-4s %-10s %-18s %-25s %-18s %-25s %-18s %-12s %-12s %-10s\n" \
  "$seq" "$dbName" "$dbUniqueName" "$PRIMARY_INSTANCES" "$standbyDBUniqueName" "$STANDBY_INSTANCES" "$STBY_ROLE" "$APPLY_LAG" "$DG_STATUS" "$READY" \
  | tee -a "$SUMMARY_FILE"

done < <(tail -n +2 "$INI_FILE" | grep -v '^$')

if [[ $WARNING_CNT -eq 0 && $NOT_READY_CNT -eq 0 && $seq -gt 0 ]]; then
  SWITCHOVER_READY="YES"
  OVERALL_STATUS="PASSED"
  EXIT_CODE=0
else
  SWITCHOVER_READY="NO"
  OVERALL_STATUS="FAILED"
  EXIT_CODE=1
fi

{
printf '%0.s_' {1..160}
echo
echo
echo "SUMMARY"
#printf '%0.s_' {1..100}
echo
echo "Total Databases      : $seq"
echo "DG Success           : $SUCCESS_CNT"
echo "DG Warning           : $WARNING_CNT"
echo "Ready for Switchover : $READY_CNT"
echo "Not Ready            : $NOT_READY_CNT"
echo
echo "SWITCHOVER READINESS"
#printf '%0.s_' {1..100}
echo
echo "READY FOR SWITCHOVER : $SWITCHOVER_READY"
echo
echo "OVERALL STATUS : $OVERALL_STATUS"
echo
echo "Summary file: $SUMMARY_FILE"
} | tee -a "$SUMMARY_FILE"

exit "$EXIT_CODE"
