#!/usr/bin/env bash

#############################################################
# Author  : Mohammed Ali
# Version : 4.1.7
# Purpose : Data Guard Control - Status/Switchover/Failover/Snapshot/Fix Broker
#############################################################

clear
set -euo pipefail
IFS=$'\n\t'

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

ACTION=""
DB_FILTER=""
RUN_SIDE=""

usage() {
cat <<EOF

Usage:
  $(basename "$0") -p --status --all
  $(basename "$0") -s --status --all
  $(basename "$0") -p --status -d MCK
  $(basename "$0") -s --status -d MCK
  $(basename "$0") -p --fix-broker -d MCK
  $(basename "$0") -s --fix-broker -d MCK
  $(basename "$0") -p --switchover -d MCK
  $(basename "$0") -s --switchover -d MCK
  $(basename "$0") -p --failover -d MCK
  $(basename "$0") -s --failover -d MCK
  $(basename "$0") -p --snapshot -d MCK
  $(basename "$0") -s --snapshot -d MCK
  $(basename "$0") -p --convert-standby -d MCK
  $(basename "$0") -s --convert-standby -d MCK

Side:
  -p, --primary         Use primary scan/service/SID from INI
  -s, --standby         Use standby scan/service/SID from INI

Actions:
  --status             Show Data Guard status
  --fix-broker         Update Broker DGConnectIdentifier and StaticConnectIdentifier
  --switchover         Perform Data Guard switchover
  --failover           Perform Data Guard failover
  --snapshot           Convert physical standby to snapshot standby/read-write
  --convert-standby    Convert snapshot standby back to physical standby

Options:
  --all                Process all databases, only valid with --status
  -d, --database       Database name or comma-separated database list
  -h, --help           Display help

EOF
exit 1
}

[[ $# -eq 0 ]] && usage

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--primary) RUN_SIDE="PRIMARY"; shift ;;
    -s|--standby) RUN_SIDE="STANDBY"; shift ;;
    --status) ACTION="STATUS"; shift ;;
    --fix-broker) ACTION="FIX_BROKER"; shift ;;
    --switchover) ACTION="SWITCHOVER"; shift ;;
    --failover) ACTION="FAILOVER"; shift ;;
    --snapshot) ACTION="SNAPSHOT"; shift ;;
    --convert-standby) ACTION="CONVERT_STANDBY"; shift ;;
    --all) DB_FILTER="ALL"; shift ;;
    -d|--database)
      [[ -z "${2:-}" ]] && usage
      DB_FILTER="$2"
      shift 2
      ;;
    -h|--help) usage ;;
    *) echo "ERROR: Invalid option: $1"; usage ;;
  esac
done

[[ -z "$RUN_SIDE" ]] && {
  echo "ERROR: Please provide -p for PRIMARY or -s for STANDBY."
  usage
}

[[ -z "$ACTION" ]] && usage
[[ -z "$DB_FILTER" ]] && usage

if [[ "$ACTION" != "STATUS" && "$DB_FILTER" == "ALL" ]]; then
  echo "ERROR: --all is only allowed with --status."
  exit 1
fi

mkdir -p "$LOG_DIR"

RUN_TS="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$LOG_DIR/dg_control_${RUN_SIDE}_${ACTION}_${RUN_TS}.log"

if [[ ! -r "$INI_FILE" ]]; then
  echo "ERROR: oracle user cannot read INI file: $INI_FILE"
  exit 1
fi

print_banner() {
  {
    echo
    echo "                              Data Guard Control - Status/Switchover/Failover/Snapshot"
    printf '%0.s_' {1..120}
    echo
    echo "Script      :  $(basename "$SCRIPT_PATH")"
    echo "Purpose     :  Data Guard Control - Status/Switchover/Failover/Snapshot/Fix Broker"
    echo "Author      :  Mohammed Ali"
    echo "Version     :  4.1.7"
    echo "Mode        :  $ACTION"
    echo "Connect Side:  $RUN_SIDE"
    echo "INI         :  $INI_FILE"
    echo "Start       :  $(date)"
    printf '%0.s_' {1..120}
    echo
  } | tee "$LOG_FILE"
}

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

build_primary_conn() {
  local dbUniqueName="$1"
  local primaryScanIPAddresses="$2"
  local primaryScanPort="$3"
  local pServiceName="$4"
  local syspass="$5"

  local PRIMARY_SCAN_HOST
  local PRIMARY_SERVICE

  PRIMARY_SCAN_HOST="${primaryScanIPAddresses%%,*}"
  PRIMARY_SERVICE="${dbUniqueName}.${pServiceName}"

  echo "sys/${syspass}@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=${PRIMARY_SCAN_HOST})(PORT=${primaryScanPort}))(CONNECT_DATA=(SERVICE_NAME=${PRIMARY_SERVICE})))"
}

build_standby_conn() {
  local standbyDBUniqueName="$1"
  local standbyScanIPAddresses="$2"
  local standbyScanPort="$3"
  local sServiceName="$4"
  local syspass="$5"

  local STANDBY_SCAN_HOST
  local STANDBY_SERVICE

  STANDBY_SCAN_HOST="${standbyScanIPAddresses%%,*}"
  STANDBY_SERVICE="${standbyDBUniqueName}.${sServiceName}"

  echo "sys/${syspass}@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=${STANDBY_SCAN_HOST})(PORT=${standbyScanPort}))(CONNECT_DATA=(SERVICE_NAME=${STANDBY_SERVICE})))"
}

build_dgmgrl_conn_by_side() {
  local dbUniqueName="$1"
  local standbyDBUniqueName="$2"
  local primaryScanIPAddresses="$3"
  local primaryScanPort="$4"
  local pServiceName="$5"
  local standbyScanIPAddresses="$6"
  local standbyScanPort="$7"
  local sServiceName="$8"
  local syspass="$9"

  if [[ "$RUN_SIDE" == "PRIMARY" ]]; then
    build_primary_conn "$dbUniqueName" "$primaryScanIPAddresses" "$primaryScanPort" "$pServiceName" "$syspass"
  else
    build_standby_conn "$standbyDBUniqueName" "$standbyScanIPAddresses" "$standbyScanPort" "$sServiceName" "$syspass"
  fi
}

run_dgmgrl() {
  local db_home="$1"
  local cmd="$2"
  local connect_str="${3:-/}"

  "$db_home/bin/dgmgrl" -silent "$connect_str" <<EOF 2>&1
$cmd
exit;
EOF
}

get_db_role() {
  local db_home="$1"
  local db_unique="$2"
  local conn="$3"

  run_dgmgrl "$db_home" "show database verbose '$db_unique';" "$conn" \
    | grep -i "^  Role:" \
    | awk -F':' '{print $2}' \
    | sed 's/^ *//;s/ *$//' \
    | head -1 || true
}

show_broker_connect_info() {
  local db_home="$1"
  local target_db="$2"
  local conn="$3"

  echo | tee -a "$LOG_FILE"
  echo "Broker Connect Identifier Check" | tee -a "$LOG_FILE"
  printf '%0.s_' {1..80} | tee -a "$LOG_FILE"
  echo | tee -a "$LOG_FILE"

  BROKER_OUT="$(run_dgmgrl "$db_home" "show database verbose '$target_db';" "$conn" || true)"

  echo "$BROKER_OUT" | egrep -i "DGConnectIdentifier|StaticConnectIdentifier|ObserverConnectIdentifier" | tee -a "$LOG_FILE" || true
}

show_status() {
  local dbName="$1"
  local dbUniqueName="$2"
  local standbyDBUniqueName="$3"
  local dbHome="$4"
  local flagSkip="$5"
  local syspass="$6"
  local primaryScanIPAddresses="$7"
  local primaryScanPort="$8"
  local pServiceName="$9"
  local standbyScanIPAddresses="${10}"
  local standbyScanPort="${11}"
  local sServiceName="${12}"

  local DGMGRL_CONN
  DGMGRL_CONN="$(build_dgmgrl_conn_by_side \
    "$dbUniqueName" \
    "$standbyDBUniqueName" \
    "$primaryScanIPAddresses" \
    "$primaryScanPort" \
    "$pServiceName" \
    "$standbyScanIPAddresses" \
    "$standbyScanPort" \
    "$sServiceName" \
    "$syspass")"

  DGOUT="$(run_dgmgrl "$dbHome" "show configuration;
show database verbose '$standbyDBUniqueName';
validate database '$standbyDBUniqueName';" "$DGMGRL_CONN" || true)"

  STBY_ROLE="$(echo "$DGOUT" | grep -i "^  Role:" | awk -F':' '{print $2}' | sed 's/^ *//;s/ *$//' | head -1 || true)"
  APPLY_LAG="$(echo "$DGOUT" | awk -F':' '/Apply Lag/ {print $2; exit}' | sed 's/(.*//;s/^ *//;s/ *$//' || true)"

  [[ -z "$STBY_ROLE" ]] && STBY_ROLE="UNKNOWN"

  if [[ "$STBY_ROLE" == "PRIMARY" ]]; then
    APPLY_LAG="N/A"
  elif [[ -z "$APPLY_LAG" ]]; then
    APPLY_LAG="UNKNOWN"
  fi

  if echo "$DGOUT" | grep -qi "SUCCESS"; then
    DG_STATUS="SUCCESS"
  else
    DG_STATUS="WARNING"
  fi

  if echo "$DGOUT" | grep -qi "Ready for Switchover:  Yes"; then
    READY="YES"
  else
    READY="NO"
  fi

  printf "%-10s %-18s %-18s %-20s %-12s %-12s %-10s %-6s\n" \
    "$dbName" "$dbUniqueName" "$standbyDBUniqueName" "$STBY_ROLE" "$APPLY_LAG" "$DG_STATUS" "$READY" "$flagSkip"
}

fix_broker_connect_identifiers() {
  local dbHome="$1"
  local dbUniqueName="$2"
  local standbyDBUniqueName="$3"
  local primaryScanIPAddresses="$4"
  local primaryScanPort="$5"
  local pServiceName="$6"
  local standbyScanIPAddresses="$7"
  local standbyScanPort="$8"
  local sServiceName="$9"
  local syspass="${10}"
  local dbSID="${11}"

  local PRIMARY_SCAN_HOST="${primaryScanIPAddresses%%,*}"
  local STANDBY_SCAN_HOST="${standbyScanIPAddresses%%,*}"
  local PRIMARY_SERVICE="${dbUniqueName}.${pServiceName}"

  local PRIMARY_DG_CONN
  local STANDBY_DG_CONN
  local PRIMARY_INST1
  local PRIMARY_INST2
  local STANDBY_INST1
  local STANDBY_INST2
  local PRIMARY_INST1_CONN
  local PRIMARY_INST2_CONN
  local STBY_INST1_CONN
  local STBY_INST2_CONN
  local DGMGRL_CONN

  PRIMARY_DG_CONN="(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=$PRIMARY_SCAN_HOST)(PORT=$primaryScanPort))(CONNECT_DATA=(SERVICE_NAME=$PRIMARY_SERVICE)))"
  STANDBY_DG_CONN="(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=$STANDBY_SCAN_HOST)(PORT=$standbyScanPort))(CONNECT_DATA=(SID=${standbyDBUniqueName}2)))"

  PRIMARY_INST1="${dbSID}1"
  PRIMARY_INST2="${dbSID}2"
  STANDBY_INST1="${standbyDBUniqueName}1"
  STANDBY_INST2="${standbyDBUniqueName}2"

  PRIMARY_INST1_CONN="(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=$PRIMARY_SCAN_HOST)(PORT=$primaryScanPort))(CONNECT_DATA=(SID=$PRIMARY_INST1)))"
  PRIMARY_INST2_CONN="(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=$PRIMARY_SCAN_HOST)(PORT=$primaryScanPort))(CONNECT_DATA=(SID=$PRIMARY_INST2)))"
  STBY_INST1_CONN="(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=$STANDBY_SCAN_HOST)(PORT=$standbyScanPort))(CONNECT_DATA=(SID=$STANDBY_INST1)))"
  STBY_INST2_CONN="(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=$STANDBY_SCAN_HOST)(PORT=$standbyScanPort))(CONNECT_DATA=(SID=$STANDBY_INST2)))"

  DGMGRL_CONN="$(build_dgmgrl_conn_by_side \
    "$dbUniqueName" \
    "$standbyDBUniqueName" \
    "$primaryScanIPAddresses" \
    "$primaryScanPort" \
    "$pServiceName" \
    "$standbyScanIPAddresses" \
    "$standbyScanPort" \
    "$sServiceName" \
    "$syspass")"

  echo | tee -a "$LOG_FILE"
  echo "Updating Broker Connect Identifiers..." | tee -a "$LOG_FILE"
  echo "Connect Side                  : $RUN_SIDE" | tee -a "$LOG_FILE"
  echo "Primary DGConnectIdentifier   : $PRIMARY_DG_CONN" | tee -a "$LOG_FILE"
  echo "Standby DGConnectIdentifier   : $STANDBY_DG_CONN" | tee -a "$LOG_FILE"
  echo "Primary Instance 1 Static     : $PRIMARY_INST1_CONN" | tee -a "$LOG_FILE"
  echo "Primary Instance 2 Static     : $PRIMARY_INST2_CONN" | tee -a "$LOG_FILE"
  echo "Standby Instance 1 Static     : $STBY_INST1_CONN" | tee -a "$LOG_FILE"
  echo "Standby Instance 2 Static     : $STBY_INST2_CONN" | tee -a "$LOG_FILE"

  run_dgmgrl "$dbHome" "
edit database '$dbUniqueName' set property DGConnectIdentifier='$PRIMARY_DG_CONN';

edit database '$standbyDBUniqueName' set property DGConnectIdentifier='$STANDBY_DG_CONN';

edit database '$standbyDBUniqueName' set property StaticConnectIdentifier='$STBY_INST2_CONN';

edit instance '$PRIMARY_INST1' on database '$dbUniqueName' set property StaticConnectIdentifier='$PRIMARY_INST1_CONN';

edit instance '$PRIMARY_INST2' on database '$dbUniqueName' set property StaticConnectIdentifier='$PRIMARY_INST2_CONN';

edit instance '$STANDBY_INST1' on database '$standbyDBUniqueName' set property StaticConnectIdentifier='$STBY_INST1_CONN';

edit instance '$STANDBY_INST2' on database '$standbyDBUniqueName' set property StaticConnectIdentifier='$STBY_INST2_CONN';

show database verbose '$dbUniqueName';
show database verbose '$standbyDBUniqueName';
show instance verbose '$STANDBY_INST1' on database '$standbyDBUniqueName';
show instance verbose '$STANDBY_INST2' on database '$standbyDBUniqueName';
" "$DGMGRL_CONN" | tee -a "$LOG_FILE"
}

pre_action_check() {
  local dbHome="$1"
  local targetDBUniqueName="$2"
  local conn="$3"

  show_broker_connect_info "$dbHome" "$targetDBUniqueName" "$conn"

  echo | tee -a "$LOG_FILE"
  echo "Running Broker validation for $targetDBUniqueName..." | tee -a "$LOG_FILE"

  VALIDATE_OUT="$(run_dgmgrl "$dbHome" "validate database '$targetDBUniqueName';" "$conn" || true)"
  echo "$VALIDATE_OUT" | tee -a "$LOG_FILE"

  if [[ "$ACTION" == "SWITCHOVER" ]] && ! echo "$VALIDATE_OUT" | grep -qi "Ready for Switchover:  Yes"; then
    echo "ERROR: Database is not ready for switchover." | tee -a "$LOG_FILE"
    return 1
  fi

  return 0
}

process_db() {
  local dbName="$1"
  local dbUniqueName="$2"
  local dbSID="$3"
  local standbyDBUniqueName="$4"
  local dbHome="$5"
  local flagSkip="$6"
  local primaryScanIPAddresses="$7"
  local primaryScanPort="$8"
  local pServiceName="$9"
  local standbyScanIPAddresses="${10}"
  local standbyScanPort="${11}"
  local sServiceName="${12}"
  local syspass="${13}"

  local DGMGRL_CONN
  local TARGET_ROLE

  DGMGRL_CONN="$(build_dgmgrl_conn_by_side \
    "$dbUniqueName" \
    "$standbyDBUniqueName" \
    "$primaryScanIPAddresses" \
    "$primaryScanPort" \
    "$pServiceName" \
    "$standbyScanIPAddresses" \
    "$standbyScanPort" \
    "$sServiceName" \
    "$syspass")"

  export ORACLE_HOME="$dbHome"
  export PATH="$ORACLE_HOME/bin:$PATH"

  if [[ "$RUN_SIDE" == "PRIMARY" ]]; then
    export ORACLE_SID="${dbSID}1"
  else
    export ORACLE_SID="${standbyDBUniqueName}1"
  fi

  if [[ "$flagSkip" == "Y" && "$ACTION" != "STATUS" ]]; then
    echo | tee -a "$LOG_FILE"
    echo "============================================================" | tee -a "$LOG_FILE"
    echo "Database : $dbName" | tee -a "$LOG_FILE"
    echo "Action   : $ACTION" | tee -a "$LOG_FILE"
    echo "Status   : SKIPPED" | tee -a "$LOG_FILE"
    echo "Reason   : flagSkip=Y in migration_db.ini" | tee -a "$LOG_FILE"
    echo "============================================================" | tee -a "$LOG_FILE"
    return
  fi

  if [[ "$ACTION" != "STATUS" ]]; then
    echo | tee -a "$LOG_FILE"
    echo "============================================================" | tee -a "$LOG_FILE"
    echo "Database     : $dbName" | tee -a "$LOG_FILE"
    echo "Primary DB   : $dbUniqueName" | tee -a "$LOG_FILE"
    echo "Standby DB   : $standbyDBUniqueName" | tee -a "$LOG_FILE"
    echo "Connect Side : $RUN_SIDE" | tee -a "$LOG_FILE"
    echo "Oracle SID   : $ORACLE_SID" | tee -a "$LOG_FILE"
    echo "flagSkip     : $flagSkip" | tee -a "$LOG_FILE"
    echo "Action       : $ACTION" | tee -a "$LOG_FILE"
    echo "Status       : EXECUTING" | tee -a "$LOG_FILE"
    echo "============================================================" | tee -a "$LOG_FILE"
  fi

  case "$ACTION" in

    STATUS)
      show_status \
        "$dbName" \
        "$dbUniqueName" \
        "$standbyDBUniqueName" \
        "$dbHome" \
        "$flagSkip" \
        "$syspass" \
        "$primaryScanIPAddresses" \
        "$primaryScanPort" \
        "$pServiceName" \
        "$standbyScanIPAddresses" \
        "$standbyScanPort" \
        "$sServiceName" | tee -a "$LOG_FILE"
      ;;

    FIX_BROKER)
      fix_broker_connect_identifiers \
        "$dbHome" \
        "$dbUniqueName" \
        "$standbyDBUniqueName" \
        "$primaryScanIPAddresses" \
        "$primaryScanPort" \
        "$pServiceName" \
        "$standbyScanIPAddresses" \
        "$standbyScanPort" \
        "$sServiceName" \
        "$syspass" \
        "$dbSID"
      ;;

    SWITCHOVER)
      TARGET_ROLE="$(get_db_role "$dbHome" "$standbyDBUniqueName" "$DGMGRL_CONN" || true)"

      if [[ "$TARGET_ROLE" == "PRIMARY" ]]; then
        echo "Target database $standbyDBUniqueName is already PRIMARY. No switchover required." | tee -a "$LOG_FILE"
        run_dgmgrl "$dbHome" "show configuration;" "$DGMGRL_CONN" | tee -a "$LOG_FILE"
        return 0
      fi

      if [[ "$TARGET_ROLE" != "PHYSICAL STANDBY" ]]; then
        echo "ERROR: Target database $standbyDBUniqueName is not PHYSICAL STANDBY. Current role: $TARGET_ROLE" | tee -a "$LOG_FILE"
        return 1
      fi

      pre_action_check "$dbHome" "$standbyDBUniqueName" "$DGMGRL_CONN" || return 1

      run_dgmgrl "$dbHome" "switchover to '$standbyDBUniqueName';
show configuration;" "$DGMGRL_CONN" | tee -a "$LOG_FILE"
      ;;

    FAILOVER)
      show_broker_connect_info "$dbHome" "$standbyDBUniqueName" "$DGMGRL_CONN"

      run_dgmgrl "$dbHome" "validate database '$standbyDBUniqueName';
failover to '$standbyDBUniqueName';
show configuration;" "$DGMGRL_CONN" | tee -a "$LOG_FILE"
      ;;

    SNAPSHOT)
      TARGET_ROLE="$(get_db_role "$dbHome" "$standbyDBUniqueName" "$DGMGRL_CONN" || true)"

      if [[ "$TARGET_ROLE" == "SNAPSHOT STANDBY" ]]; then
        echo "$standbyDBUniqueName is already SNAPSHOT STANDBY / read-write mode." | tee -a "$LOG_FILE"
        echo "Converting $standbyDBUniqueName back to PHYSICAL STANDBY because flagSkip=N." | tee -a "$LOG_FILE"

        run_dgmgrl "$dbHome" "convert database '$standbyDBUniqueName' to physical standby;
show configuration;" "$DGMGRL_CONN" | tee -a "$LOG_FILE"
        return
      fi

      show_broker_connect_info "$dbHome" "$standbyDBUniqueName" "$DGMGRL_CONN"

      run_dgmgrl "$dbHome" "convert database '$standbyDBUniqueName' to snapshot standby;
show configuration;" "$DGMGRL_CONN" | tee -a "$LOG_FILE"
      ;;

    CONVERT_STANDBY)
      show_broker_connect_info "$dbHome" "$standbyDBUniqueName" "$DGMGRL_CONN"

      run_dgmgrl "$dbHome" "convert database '$standbyDBUniqueName' to physical standby;
show configuration;" "$DGMGRL_CONN" | tee -a "$LOG_FILE"
      ;;

  esac
}

print_banner

if [[ "$ACTION" == "STATUS" ]]; then
  printf "\n%-10s %-18s %-18s %-20s %-12s %-12s %-10s %-6s\n" \
    "DB_NAME" "PRIMARY_DB" "STANDBY_DB" "STBY_ROLE" "APPLY_LAG" "DG_STATUS" "READY" "SKIP" \
    | tee -a "$LOG_FILE"
  printf '%0.s_' {1..115} | tee -a "$LOG_FILE"
  echo | tee -a "$LOG_FILE"
fi

MATCH_CNT=0

while IFS='|' read -r \
dbName dbUniqueName dbSID dbCharset dbNCharset pdatafileDestination pfraDestination pNodeList port syspass tdepass \
primaryScanIPAddresses primaryScanPort pServiceName standbyScanIPAddresses standbyScanPort sServiceName standbyDBUniqueName \
sdatafileDestination sfraDestination sNodeList flagSkip dbBlockSizeInKB enableCDB dbHome
do
  dbName="$(echo "${dbName:-}" | tr -d '\r' | sed 's/^ *//;s/ *$//')"
  dbUniqueName="$(echo "${dbUniqueName:-}" | tr -d '\r' | sed 's/^ *//;s/ *$//')"
  dbSID="$(echo "${dbSID:-}" | tr -d '\r' | sed 's/^ *//;s/ *$//')"
  syspass="$(echo "${syspass:-}" | tr -d '\r' | sed 's/^ *//;s/ *$//')"
  primaryScanIPAddresses="$(echo "${primaryScanIPAddresses:-}" | tr -d '\r' | sed 's/^ *//;s/ *$//')"
  primaryScanPort="$(echo "${primaryScanPort:-}" | tr -d '\r' | sed 's/^ *//;s/ *$//')"
  pServiceName="$(echo "${pServiceName:-}" | tr -d '\r' | sed 's/^ *//;s/ *$//')"
  standbyScanIPAddresses="$(echo "${standbyScanIPAddresses:-}" | tr -d '\r' | sed 's/^ *//;s/ *$//')"
  standbyScanPort="$(echo "${standbyScanPort:-}" | tr -d '\r' | sed 's/^ *//;s/ *$//')"
  sServiceName="$(echo "${sServiceName:-}" | tr -d '\r' | sed 's/^ *//;s/ *$//')"
  standbyDBUniqueName="$(echo "${standbyDBUniqueName:-}" | tr -d '\r' | sed 's/^ *//;s/ *$//')"
  flagSkip="$(echo "${flagSkip:-N}" | tr -d '\r' | sed 's/^ *//;s/ *$//' | tr '[:lower:]' '[:upper:]')"
  dbHome="$(echo "${dbHome:-}" | tr -d '\r' | sed 's/^ *//;s/ *$//')"

  [[ -z "$dbName" ]] && continue
  is_selected_db "$dbName" || continue

  if [[ -z "$dbHome" || ! -x "$dbHome/bin/dgmgrl" ]]; then
    echo "WARNING: Skipping $dbName - invalid dbHome: $dbHome" | tee -a "$LOG_FILE"
    continue
  fi

  ((++MATCH_CNT))

  process_db \
    "$dbName" \
    "$dbUniqueName" \
    "$dbSID" \
    "$standbyDBUniqueName" \
    "$dbHome" \
    "$flagSkip" \
    "$primaryScanIPAddresses" \
    "$primaryScanPort" \
    "$pServiceName" \
    "$standbyScanIPAddresses" \
    "$standbyScanPort" \
    "$sServiceName" \
    "$syspass"

done < <(tail -n +2 "$INI_FILE" | grep -v '^$')

if [[ "$MATCH_CNT" -eq 0 ]]; then
  echo "ERROR: No matching database found for selection: $DB_FILTER" | tee -a "$LOG_FILE"
  exit 1
fi

echo
echo "Log file: $LOG_FILE"

