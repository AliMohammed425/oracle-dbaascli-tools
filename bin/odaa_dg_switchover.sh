#!/usr/bin/env bash

#############################################################
# Author  : Mohammed Ali
# Version : 5.1.1
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
    TNS_ADMIN="${TNS_ADMIN:-}" \
    "$SCRIPT_PATH" "$@"
fi

ACTION=""
DB_FILTER=""
RUN_SIDE=""
DRY_RUN="N"
VERBOSE="N"

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
  $(basename "$0") -s --switchover -d POC,MCK,MCK16
  $(basename "$0") -s --switchover --all
  $(basename "$0") -p --switchover -d POC,MCK,MCK16
  $(basename "$0") -p --switchover --all
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
  --all                Process all databases. For switchover/failover/snapshot requires confirmation
  -d, --database       Database name or comma-separated list, example POC,MCK,MCK16
  --dry-run           Preview Broker changes without modifying anything
  --verbose           Print detailed diagnostics
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
    --dry-run) DRY_RUN="Y"; shift ;;
    --verbose) VERBOSE="Y"; shift ;;
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

if [[ "$DB_FILTER" == "ALL" && "$ACTION" != "STATUS" ]]; then
  echo
  echo "WARNING: You are about to run $ACTION for ALL databases in: $INI_FILE"
  echo "Connect Side: $RUN_SIDE"
  echo "Rule: -s switches to standby side, -p switches back to primary side"
  read -r -p "Type YES to continue: " CONFIRM_ALL
  if [[ "$CONFIRM_ALL" != "YES" ]]; then
    echo "Cancelled by user."
    exit 1
  fi
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
    echo "Version     :  5.1.1"
    echo "Mode        :  $ACTION"
    echo "Connect Side:  $RUN_SIDE"
    echo "Dry Run     :  $DRY_RUN"
    echo "Verbose     :  $VERBOSE"
    echo "INI         :  $INI_FILE"
    echo "Start       :  $(date)"
    printf '%0.s_' {1..120}
    echo
  } | tee "$LOG_FILE"
}

log_both() {
  echo "$*" | tee -a "$LOG_FILE"
}

log_only() {
  echo "$*" >> "$LOG_FILE"
}

log_output() {
  local title="$1"
  local output="${2:-}"

  {
    echo
    echo "$title "
    echo "$output"
    echo "END $title"
  } >> "$LOG_FILE"

  if [[ "$VERBOSE" == "Y" ]]; then
    echo "$output"
  fi
}

first_error_line() {
  echo "${1:-}" | grep -E "ORA-|TNS-|Failed\.|Unable to connect|not logged on" | head -1 | sed 's/^ *//;s/ *$//' || true
}

success_from_output() {
  local output="${1:-}"
  if echo "$output" | grep -qiE "ORA-|TNS-|Failed\.|Unable to connect|not logged on"; then
    return 1
  fi
  return 0
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

  # Version 5.0.1 fix:
  # For DGMGRL connection itself, always prefer the working TNS alias.
  # This fixes -s/--standby where generated SERVICE_NAME descriptor can fail with ORA-12514.
  if tns_alias_ok "$dbUniqueName"; then
    echo "sys/${syspass}@${dbUniqueName}"
  else
    echo "sys/${syspass}@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=${PRIMARY_SCAN_HOST})(PORT=${primaryScanPort}))(CONNECT_DATA=(SERVICE_NAME=${PRIMARY_SERVICE})))"
  fi
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

  # Version 5.0.1 fix:
  # For -s/--standby, connect DGMGRL using the alias POC_OCI when tnsping works.
  # Do not connect using generated SERVICE_NAME descriptor first.
  if tns_alias_ok "$standbyDBUniqueName"; then
    echo "sys/${syspass}@${standbyDBUniqueName}"
  else
    echo "sys/${syspass}@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=${STANDBY_SCAN_HOST})(PORT=${standbyScanPort}))(CONNECT_DATA=(SERVICE_NAME=${STANDBY_SERVICE})))"
  fi
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

  if [[ "$VERBOSE" == "Y" ]]; then
    echo "[VERBOSE] DGMGRL connect: $connect_str" >&2
    echo "[VERBOSE] DGMGRL command:" >&2
    echo "$cmd" >&2
  fi

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

get_broker_instances() {
  local dbHome="$1"
  local target_db="$2"
  local conn="$3"

  run_dgmgrl "$dbHome" "show database verbose '$target_db';" "$conn" \
    | awk '
      BEGIN { in_instances=0 }
      /^[[:space:]]*Instance\(s\):/ { in_instances=1; next }
      in_instances && /^[[:space:]]*Properties:/ { exit }
      in_instances && NF {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
        if ($0 !~ /^$/) print $1
      }
    ' \
    | grep -viE '^(Database|Role:|Intended|Properties:)$' || true
}

build_static_conn() {
  local host="$1"
  local port="$2"
  local sid="$3"

  echo "(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=${host})(PORT=${port}))(CONNECT_DATA=(SID=${sid})))"
}

tns_alias_ok() {
  local alias_name="$1"

  [[ -z "$alias_name" ]] && return 1
  tnsping "$alias_name" >/dev/null 2>&1
}

sqlplus_connect_ok() {
  local connect_str="$1"
  local syspass="$2"

  [[ -z "$connect_str" || -z "$syspass" ]] && return 1

  sqlplus -L -s /nolog <<EOF >/dev/null 2>&1
whenever sqlerror exit failure
connect sys/${syspass}@${connect_str} as sysdba
select 1 from dual;
exit;
EOF
}

extract_broker_dg_identifier() {
  local dbHome="$1"
  local target_db="$2"
  local conn="$3"

  run_dgmgrl "$dbHome" "show database verbose '$target_db';" "$conn" \
    | awk -F"'" '/DGConnectIdentifier[[:space:]]*=/{print $2; exit}' \
    | sed 's/^ *//;s/ *$//' || true
}

ezconnect_ok() {
  local scan_host="$1"
  local scan_port="$2"
  local service_name="$3"
  local syspass="$4"

  sqlplus_connect_ok "${scan_host}:${scan_port}/${service_name}" "$syspass"
}

descriptor_ok() {
  local descriptor="$1"
  local syspass="$2"

  sqlplus_connect_ok "$descriptor" "$syspass"
}

build_descriptor() {
  local scan_host="$1"
  local scan_port="$2"
  local service_name="$3"

  echo "(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=${scan_host})(PORT=${scan_port}))(CONNECT_DATA=(SERVICE_NAME=${service_name})))"
}

build_broker_dg_identifier() {
  local dbHome="$1"
  local target_db="$2"
  local alias_name="$3"
  local scan_host="$4"
  local scan_port="$5"
  local service_name="$6"
  local syspass="$7"
  local dgmgrl_conn="$8"

  local existing=""
  local ezconn="${scan_host}:${scan_port}/${service_name}"
  local descriptor=""

  descriptor="$(build_descriptor "$scan_host" "$scan_port" "$service_name")"
  existing="$(extract_broker_dg_identifier "$dbHome" "$target_db" "$dgmgrl_conn")"

  log_only "Checking DGConnectIdentifier candidates for $target_db..."
  log_only "  TNS_ADMIN=${TNS_ADMIN:-NOT_SET}"
  [[ "$VERBOSE" == "Y" ]] && echo "Checking DGConnectIdentifier candidates for $target_db..." >&2
  [[ "$VERBOSE" == "Y" ]] && echo "  TNS_ADMIN=${TNS_ADMIN:-NOT_SET}" >&2

  # Priority 1: keep the working TNS alias exactly as-is.
  # This avoids replacing POC_OCI with a generated service descriptor that can fail with ORA-12514.
  if tns_alias_ok "$alias_name"; then
    log_only "  OK TNS alias via tnsping: $alias_name"
    [[ "$VERBOSE" == "Y" ]] && echo "  OK TNS alias via tnsping: $alias_name" >&2
    echo "$alias_name"
    return 0
  fi

  # Priority 2: existing Broker value, only if SQL*Plus can connect to it.
  if [[ -n "$existing" ]] && sqlplus_connect_ok "$existing" "$syspass"; then
    log_only "  OK existing Broker value: $existing"
    [[ "$VERBOSE" == "Y" ]] && echo "  OK existing Broker value: $existing" >&2
    echo "$existing"
    return 0
  fi

  # Priority 3: EZCONNECT host:port/service.
  if ezconnect_ok "$scan_host" "$scan_port" "$service_name" "$syspass"; then
    log_only "  OK EZCONNECT: $ezconn"
    [[ "$VERBOSE" == "Y" ]] && echo "  OK EZCONNECT: $ezconn" >&2
    echo "$ezconn"
    return 0
  fi

  # Priority 4: full DESCRIPTION descriptor.
  if descriptor_ok "$descriptor" "$syspass"; then
    log_only "  OK DESCRIPTION descriptor"
    [[ "$VERBOSE" == "Y" ]] && echo "  OK DESCRIPTION descriptor" >&2
    echo "$descriptor"
    return 0
  fi

  log_only "  WARNING: all validations failed. Falling back to DESCRIPTION descriptor."
  [[ "$VERBOSE" == "Y" ]] && echo "  WARNING: all validations failed. Falling back to DESCRIPTION descriptor." >&2
  echo "$descriptor"
}

run_dgmgrl_checked() {
  local dbHome="$1"
  local cmds="$2"
  local conn="$3"

  if [[ "$DRY_RUN" == "Y" ]]; then
    echo
    echo "DRY-RUN: DGMGRL commands not executed:"
    echo "------------------------------------------------------------"
    echo "$cmds"
    echo "------------------------------------------------------------"
    return 0
  fi

  run_dgmgrl "$dbHome" "$cmds" "$conn"
}

validate_broker_after_fix() {
  local dbHome="$1"
  local primary_db="$2"
  local standby_db="$3"
  local conn="$4"

  local out
  out="$(run_dgmgrl "$dbHome" "show database verbose '$primary_db';
show database verbose '$standby_db';
validate database '$standby_db';" "$conn" || true)"
  echo "$out"

  if echo "$out" | grep -qiE "ORA-12154|ORA-12514|Failed\.|Unable to connect|not logged on"; then
    return 1
  fi

  return 0
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
  local STANDBY_SERVICE="${standbyDBUniqueName}.${sServiceName}"

  local PRIMARY_DG_CONN
  local STANDBY_DG_CONN
  local DGMGRL_CONN
  local DGMGRL_CMDS
  local PRIMARY_INSTANCES
  local STANDBY_INSTANCES
  local inst
  local static_conn

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

  PRIMARY_DG_CONN="$(build_broker_dg_identifier "$dbHome" "$dbUniqueName" "$dbUniqueName" "$PRIMARY_SCAN_HOST" "$primaryScanPort" "$PRIMARY_SERVICE" "$syspass" "$DGMGRL_CONN")"
  STANDBY_DG_CONN="$(build_broker_dg_identifier "$dbHome" "$standbyDBUniqueName" "$standbyDBUniqueName" "$STANDBY_SCAN_HOST" "$standbyScanPort" "$STANDBY_SERVICE" "$syspass" "$DGMGRL_CONN")"

  echo | tee -a "$LOG_FILE"
  echo "Updating Broker Connect Identifiers..." | tee -a "$LOG_FILE"
  echo "Connect Side                  : $RUN_SIDE" | tee -a "$LOG_FILE"
  echo "Primary DGConnectIdentifier   : $PRIMARY_DG_CONN" | tee -a "$LOG_FILE"
  echo "Standby DGConnectIdentifier   : $STANDBY_DG_CONN" | tee -a "$LOG_FILE"
  echo "NOTE                          : DGConnectIdentifier priority: TNS alias first, existing valid Broker value, EZCONNECT, DESCRIPTION descriptor." | tee -a "$LOG_FILE"
  echo "NOTE                          : StaticConnectIdentifier is instance-specific only." | tee -a "$LOG_FILE"

  PRIMARY_INSTANCES="$(get_broker_instances "$dbHome" "$dbUniqueName" "$DGMGRL_CONN")"
  STANDBY_INSTANCES="$(get_broker_instances "$dbHome" "$standbyDBUniqueName" "$DGMGRL_CONN")"

  if [[ -z "$PRIMARY_INSTANCES" ]]; then
    echo "WARNING: Broker primary instance list not found for $dbUniqueName. Falling back to ${dbSID}1 ${dbSID}2." | tee -a "$LOG_FILE"
    PRIMARY_INSTANCES="$(printf "%s\n%s\n" "${dbSID}1" "${dbSID}2")"
  fi

  if [[ -z "$STANDBY_INSTANCES" ]]; then
    echo "WARNING: Broker standby instance list not found for $standbyDBUniqueName. Static standby instance update will be skipped." | tee -a "$LOG_FILE"
  fi

  DGMGRL_CMDS="
edit database '$dbUniqueName' set property DGConnectIdentifier='$PRIMARY_DG_CONN';
edit database '$standbyDBUniqueName' set property DGConnectIdentifier='$STANDBY_DG_CONN';
"

  echo | tee -a "$LOG_FILE"
  echo "Broker Primary Instances Found:" | tee -a "$LOG_FILE"
  echo "$PRIMARY_INSTANCES" | sed '/^$/d;s/^/  - /' | tee -a "$LOG_FILE"

  while IFS= read -r inst; do
    [[ -z "$inst" ]] && continue
    static_conn="$(build_static_conn "$PRIMARY_SCAN_HOST" "$primaryScanPort" "$inst")"
    echo "Primary Instance Static       : $inst => $static_conn" | tee -a "$LOG_FILE"
    DGMGRL_CMDS+="
edit instance '$inst' on database '$dbUniqueName' set property StaticConnectIdentifier='$static_conn';
"
  done <<< "$PRIMARY_INSTANCES"

  echo | tee -a "$LOG_FILE"
  echo "Broker Standby Instances Found:" | tee -a "$LOG_FILE"
  if [[ -n "$STANDBY_INSTANCES" ]]; then
    echo "$STANDBY_INSTANCES" | sed '/^$/d;s/^/  - /' | tee -a "$LOG_FILE"

    while IFS= read -r inst; do
      [[ -z "$inst" ]] && continue
      static_conn="$(build_static_conn "$STANDBY_SCAN_HOST" "$standbyScanPort" "$inst")"
      echo "Standby Instance Static       : $inst => $static_conn" | tee -a "$LOG_FILE"
      DGMGRL_CMDS+="
edit instance '$inst' on database '$standbyDBUniqueName' set property StaticConnectIdentifier='$static_conn';
"
    done <<< "$STANDBY_INSTANCES"
  else
    echo "  - NONE FOUND / SKIPPED" | tee -a "$LOG_FILE"
  fi

  DGMGRL_CMDS+="
show database verbose '$dbUniqueName';
show database verbose '$standbyDBUniqueName';
"

  while IFS= read -r inst; do
    [[ -z "$inst" ]] && continue
    DGMGRL_CMDS+="
show instance verbose '$inst' on database '$dbUniqueName';
"
  done <<< "$PRIMARY_INSTANCES"

  while IFS= read -r inst; do
    [[ -z "$inst" ]] && continue
    DGMGRL_CMDS+="
show instance verbose '$inst' on database '$standbyDBUniqueName';
"
  done <<< "$STANDBY_INSTANCES"

  FIX_OUT="$(run_dgmgrl_checked "$dbHome" "$DGMGRL_CMDS" "$DGMGRL_CONN" || true)"
  log_output "DGMGRL BROKER FIX - $dbUniqueName/$standbyDBUniqueName" "$FIX_OUT"
  if success_from_output "$FIX_OUT"; then
    log_both "Broker connect identifier update completed."
  else
    log_both "Broker connect identifier update failed."
    ERR_LINE="$(first_error_line "$FIX_OUT")"
    [[ -n "$ERR_LINE" ]] && log_both "Reason: $ERR_LINE"
  fi

  if [[ "$DRY_RUN" == "Y" ]]; then
    return 0
  fi

  ACTUAL_PRIMARY_DG="$(extract_broker_dg_identifier "$dbHome" "$dbUniqueName" "$DGMGRL_CONN")"
  ACTUAL_STANDBY_DG="$(extract_broker_dg_identifier "$dbHome" "$standbyDBUniqueName" "$DGMGRL_CONN")"

  echo | tee -a "$LOG_FILE"
  echo "Broker DGConnectIdentifier Verification:" | tee -a "$LOG_FILE"
  echo "  Primary intended : $PRIMARY_DG_CONN" | tee -a "$LOG_FILE"
  echo "  Primary actual   : $ACTUAL_PRIMARY_DG" | tee -a "$LOG_FILE"
  echo "  Standby intended : $STANDBY_DG_CONN" | tee -a "$LOG_FILE"
  echo "  Standby actual   : $ACTUAL_STANDBY_DG" | tee -a "$LOG_FILE"

  if [[ "$ACTUAL_PRIMARY_DG" != "$PRIMARY_DG_CONN" || "$ACTUAL_STANDBY_DG" != "$STANDBY_DG_CONN" ]]; then
    echo "ERROR: Broker DGConnectIdentifier does not match intended value. Stopping before switchover." | tee -a "$LOG_FILE"
    return 1
  fi

  log_both "Validating Broker after connect identifier update..."
  VALIDATE_FIX_OUT="$(validate_broker_after_fix "$dbHome" "$dbUniqueName" "$standbyDBUniqueName" "$DGMGRL_CONN" || true)"
  log_output "DGMGRL VALIDATE AFTER FIX - $dbUniqueName/$standbyDBUniqueName" "$VALIDATE_FIX_OUT"
  if ! success_from_output "$VALIDATE_FIX_OUT"; then
    log_both "ERROR: Broker validation failed after update. Check listener/TNS/service registration before switchover."
    ERR_LINE="$(first_error_line "$VALIDATE_FIX_OUT")"
    [[ -n "$ERR_LINE" ]] && log_both "Reason: $ERR_LINE"
    return 1
  fi
  log_both "Broker validation passed."
}

pre_action_check() {
  local dbHome="$1"
  local targetDBUniqueName="$2"
  local conn="$3"

  show_broker_connect_info "$dbHome" "$targetDBUniqueName" "$conn"

  echo | tee -a "$LOG_FILE"
  echo "Running Broker validation for $targetDBUniqueName..." | tee -a "$LOG_FILE"

  VALIDATE_OUT="$(run_dgmgrl "$dbHome" "validate database '$targetDBUniqueName';" "$conn" || true)"
  log_output "DGMGRL VALIDATE DATABASE - $targetDBUniqueName" "$VALIDATE_OUT"

  if [[ "$ACTION" == "SWITCHOVER" ]] && ! echo "$VALIDATE_OUT" | grep -qi "Ready for Switchover:  Yes"; then
    log_both "ERROR: Database is not ready for switchover."
    ERR_LINE="$(first_error_line "$VALIDATE_OUT")"
    [[ -n "$ERR_LINE" ]] && log_both "Reason: $ERR_LINE"
    return 1
  fi

  log_both "Broker validation passed."
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

  export ORACLE_HOME="$dbHome"
  export PATH="$ORACLE_HOME/bin:$PATH"

  # Use the database-specific network admin directory before building any DGMGRL connection.
  # Required for -s/--standby because POC_OCI exists under $ORACLE_HOME/network/admin/<DB_NAME>.
  if [[ -d "$ORACLE_HOME/network/admin/$dbName" ]]; then
    export TNS_ADMIN="$ORACLE_HOME/network/admin/$dbName"
  elif [[ -z "${TNS_ADMIN:-}" && -d "$ORACLE_HOME/network/admin" ]]; then
    export TNS_ADMIN="$ORACLE_HOME/network/admin"
  fi

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

  if [[ "$RUN_SIDE" == "PRIMARY" ]]; then
    export ORACLE_SID="${dbSID}1"
  else
    export ORACLE_SID="${standbyDBUniqueName}1"
  fi

  if [[ "$flagSkip" == "Y" && "$ACTION" != "STATUS" ]]; then
    echo | tee -a "$LOG_FILE"
    echo " " | tee -a "$LOG_FILE"
    echo "Database : $dbName" | tee -a "$LOG_FILE"
    echo "Action   : $ACTION" | tee -a "$LOG_FILE"
    echo "Status   : SKIPPED" | tee -a "$LOG_FILE"
    echo "Reason   : flagSkip=Y in migration_db.ini" | tee -a "$LOG_FILE"
    echo " " | tee -a "$LOG_FILE"
    return
  fi

  if [[ "$ACTION" != "STATUS" ]]; then
    echo | tee -a "$LOG_FILE"
    echo " " | tee -a "$LOG_FILE"
    echo "Database     : $dbName" | tee -a "$LOG_FILE"
    echo "Primary DB   : $dbUniqueName" | tee -a "$LOG_FILE"
    echo "Standby DB   : $standbyDBUniqueName" | tee -a "$LOG_FILE"
    echo "Connect Side : $RUN_SIDE" | tee -a "$LOG_FILE"
    echo "Oracle SID   : $ORACLE_SID" | tee -a "$LOG_FILE"
    echo "TNS_ADMIN    : ${TNS_ADMIN:-NOT_SET}" | tee -a "$LOG_FILE"
    echo "flagSkip     : $flagSkip" | tee -a "$LOG_FILE"
    echo "Action       : $ACTION" | tee -a "$LOG_FILE"
    echo "Status       : EXECUTING" | tee -a "$LOG_FILE"
    echo " " | tee -a "$LOG_FILE"
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
      echo "Auto-fixing Broker connect identifiers before switchover..." | tee -a "$LOG_FILE"
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

      # Version 5.1.0 behavior:
      #   -s / --standby  : switchover TO standby unique name, for example POC_OCI
      #   -p / --primary  : switchover BACK TO primary unique name, for example POC_EXA
      # This allows the same script to move forward from primary to standby and move back from standby to primary.
      local SWITCH_TARGET_DB=""
      if [[ "$RUN_SIDE" == "STANDBY" ]]; then
        SWITCH_TARGET_DB="$standbyDBUniqueName"
      else
        SWITCH_TARGET_DB="$dbUniqueName"
      fi

      echo "Switchover Target            : $SWITCH_TARGET_DB" | tee -a "$LOG_FILE"
      echo "Rule                         : -s switches to standby side, -p switches back to primary side" | tee -a "$LOG_FILE"

      TARGET_ROLE="$(get_db_role "$dbHome" "$SWITCH_TARGET_DB" "$DGMGRL_CONN" || true)"

      if [[ "$TARGET_ROLE" == "PRIMARY" ]]; then
        log_both "Target database $SWITCH_TARGET_DB is already PRIMARY. No switchover required."
        SHOW_OUT="$(run_dgmgrl "$dbHome" "show configuration;" "$DGMGRL_CONN" || true)"
        log_output "DGMGRL SHOW CONFIGURATION - $dbName" "$SHOW_OUT"
        return 0
      fi

      if [[ "$TARGET_ROLE" != "PHYSICAL STANDBY" ]]; then
        echo "ERROR: Target database $SWITCH_TARGET_DB is not PHYSICAL STANDBY. Current role: $TARGET_ROLE" | tee -a "$LOG_FILE"
        return 1
      fi

      pre_action_check "$dbHome" "$SWITCH_TARGET_DB" "$DGMGRL_CONN" || return 1

      if [[ "$DRY_RUN" == "Y" ]]; then
        echo "DRY-RUN: switchover to '$SWITCH_TARGET_DB';" | tee -a "$LOG_FILE"
        return 0
      fi

      SWITCH_OUT="$(run_dgmgrl "$dbHome" "switchover to '$SWITCH_TARGET_DB';
show configuration;" "$DGMGRL_CONN" || true)"
      log_output "DGMGRL SWITCHOVER - $dbName TO $SWITCH_TARGET_DB" "$SWITCH_OUT"
      if success_from_output "$SWITCH_OUT"; then
        log_both "Switchover command completed."
      else
        log_both "Switchover command failed."
        ERR_LINE="$(first_error_line "$SWITCH_OUT")"
        [[ -n "$ERR_LINE" ]] && log_both "Reason: $ERR_LINE"
      fi

      if echo "$SWITCH_OUT" | grep -qiE "ORA-12154|ORA-12514|Unable to connect|Failed to attach"; then
        echo "Detected Broker connect error during switchover. Auto-repairing Broker and retrying once..." | tee -a "$LOG_FILE"
        fix_broker_connect_identifiers           "$dbHome"           "$dbUniqueName"           "$standbyDBUniqueName"           "$primaryScanIPAddresses"           "$primaryScanPort"           "$pServiceName"           "$standbyScanIPAddresses"           "$standbyScanPort"           "$sServiceName"           "$syspass"           "$dbSID" || return 1

        DGMGRL_CONN="$(build_dgmgrl_conn_by_side           "$dbUniqueName"           "$standbyDBUniqueName"           "$primaryScanIPAddresses"           "$primaryScanPort"           "$pServiceName"           "$standbyScanIPAddresses"           "$standbyScanPort"           "$sServiceName"           "$syspass")"

        RETRY_OUT="$(run_dgmgrl "$dbHome" "switchover to '$SWITCH_TARGET_DB';
show configuration;" "$DGMGRL_CONN" || true)"
        log_output "DGMGRL SWITCHOVER RETRY - $dbName TO $SWITCH_TARGET_DB" "$RETRY_OUT"
        if success_from_output "$RETRY_OUT"; then
          log_both "Switchover retry completed."
        else
          log_both "Switchover retry failed."
          ERR_LINE="$(first_error_line "$RETRY_OUT")"
          [[ -n "$ERR_LINE" ]] && log_both "Reason: $ERR_LINE"
        fi
      fi
      ;;

    FAILOVER)
      show_broker_connect_info "$dbHome" "$standbyDBUniqueName" "$DGMGRL_CONN"

      [[ "$DRY_RUN" == "Y" ]] && { echo "DRY-RUN: failover action skipped." | tee -a "$LOG_FILE"; return 0; }

      FAIL_OUT="$(run_dgmgrl "$dbHome" "validate database '$standbyDBUniqueName';
failover to '$standbyDBUniqueName';
show configuration;" "$DGMGRL_CONN" || true)"
      log_output "DGMGRL FAILOVER - $dbName TO $standbyDBUniqueName" "$FAIL_OUT"
      if success_from_output "$FAIL_OUT"; then log_both "Failover command completed."; else log_both "Failover command failed."; ERR_LINE="$(first_error_line "$FAIL_OUT")"; [[ -n "$ERR_LINE" ]] && log_both "Reason: $ERR_LINE"; fi
      ;;

    SNAPSHOT)
      TARGET_ROLE="$(get_db_role "$dbHome" "$standbyDBUniqueName" "$DGMGRL_CONN" || true)"

      if [[ "$TARGET_ROLE" == "SNAPSHOT STANDBY" ]]; then
        echo "$standbyDBUniqueName is already SNAPSHOT STANDBY / read-write mode." | tee -a "$LOG_FILE"
        echo "Converting $standbyDBUniqueName back to PHYSICAL STANDBY because flagSkip=N." | tee -a "$LOG_FILE"

        CONVERT_OUT="$(run_dgmgrl "$dbHome" "convert database '$standbyDBUniqueName' to physical standby;
show configuration;" "$DGMGRL_CONN" || true)"
        log_output "DGMGRL CONVERT TO PHYSICAL - $dbName" "$CONVERT_OUT"
        if success_from_output "$CONVERT_OUT"; then log_both "Convert to physical standby completed."; else log_both "Convert to physical standby failed."; ERR_LINE="$(first_error_line "$CONVERT_OUT")"; [[ -n "$ERR_LINE" ]] && log_both "Reason: $ERR_LINE"; fi
        return
      fi

      show_broker_connect_info "$dbHome" "$standbyDBUniqueName" "$DGMGRL_CONN"

      SNAP_OUT="$(run_dgmgrl "$dbHome" "convert database '$standbyDBUniqueName' to snapshot standby;
show configuration;" "$DGMGRL_CONN" || true)"
      log_output "DGMGRL CONVERT TO SNAPSHOT - $dbName" "$SNAP_OUT"
      if success_from_output "$SNAP_OUT"; then log_both "Convert to snapshot standby completed."; else log_both "Convert to snapshot standby failed."; ERR_LINE="$(first_error_line "$SNAP_OUT")"; [[ -n "$ERR_LINE" ]] && log_both "Reason: $ERR_LINE"; fi
      ;;

    CONVERT_STANDBY)
      show_broker_connect_info "$dbHome" "$standbyDBUniqueName" "$DGMGRL_CONN"

      CONVERT_OUT="$(run_dgmgrl "$dbHome" "convert database '$standbyDBUniqueName' to physical standby;
show configuration;" "$DGMGRL_CONN" || true)"
      log_output "DGMGRL CONVERT TO PHYSICAL - $dbName" "$CONVERT_OUT"
      if success_from_output "$CONVERT_OUT"; then log_both "Convert to physical standby completed."; else log_both "Convert to physical standby failed."; ERR_LINE="$(first_error_line "$CONVERT_OUT")"; [[ -n "$ERR_LINE" ]] && log_both "Reason: $ERR_LINE"; fi
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
SUCCESS_CNT=0
FAILED_CNT=0
SKIPPED_CNT=0
RESULT_ROWS=()

add_result_row() {
  local seq="$1"
  local db="$2"
  local result="$3"
  local target="$4"
  local note="${5:-}"
  RESULT_ROWS+=("$(printf '%-5s %-14s %-12s %-18s %s' "$seq" "$db" "$result" "$target" "$note")")
}

print_summary() {
  [[ "$ACTION" == "STATUS" ]] && return 0
  echo | tee -a "$LOG_FILE"
  echo " " | tee -a "$LOG_FILE"
  echo "$ACTION SUMMARY" | tee -a "$LOG_FILE"
  echo " " | tee -a "$LOG_FILE"
  echo "Processed  : $MATCH_CNT" | tee -a "$LOG_FILE"
  echo "Successful : $SUCCESS_CNT" | tee -a "$LOG_FILE"
  echo "Failed     : $FAILED_CNT" | tee -a "$LOG_FILE"
  echo "Skipped    : $SKIPPED_CNT" | tee -a "$LOG_FILE"
  echo | tee -a "$LOG_FILE"
  printf '%-5s %-14s %-12s %-18s %s
' "SEQ" "DB_NAME" "RESULT" "TARGET" "NOTE" | tee -a "$LOG_FILE"
  printf '%0.s-' {1..80} | tee -a "$LOG_FILE"
  echo | tee -a "$LOG_FILE"
  local row
  for row in "${RESULT_ROWS[@]}"; do
    echo "$row" | tee -a "$LOG_FILE"
  done
  echo " " | tee -a "$LOG_FILE"
}

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

  TARGET_DB="N/A"
  if [[ "$ACTION" == "SWITCHOVER" ]]; then
    if [[ "$RUN_SIDE" == "STANDBY" ]]; then
      TARGET_DB="$standbyDBUniqueName"
    else
      TARGET_DB="$dbUniqueName"
    fi
  elif [[ "$ACTION" == "FAILOVER" || "$ACTION" == "SNAPSHOT" || "$ACTION" == "CONVERT_STANDBY" ]]; then
    TARGET_DB="$standbyDBUniqueName"
  fi

  if [[ "$flagSkip" == "Y" && "$ACTION" != "STATUS" ]]; then
    ((++SKIPPED_CNT))
    add_result_row "$MATCH_CNT" "$dbName" "SKIPPED" "$TARGET_DB" "flagSkip=Y"
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
      "$syspass" || true
    continue
  fi

  if process_db \
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
    "$syspass"; then
    if [[ "$ACTION" != "STATUS" ]]; then
      ((++SUCCESS_CNT))
      add_result_row "$MATCH_CNT" "$dbName" "SUCCESS" "$TARGET_DB" "completed"
    fi
  else
    if [[ "$ACTION" != "STATUS" ]]; then
      ((++FAILED_CNT))
      add_result_row "$MATCH_CNT" "$dbName" "FAILED" "$TARGET_DB" "check log"
      echo "WARNING: $dbName failed. Continuing with next selected database..." | tee -a "$LOG_FILE"
    fi
  fi

done < <(tail -n +2 "$INI_FILE" | grep -v '^$')

if [[ "$MATCH_CNT" -eq 0 ]]; then
  echo "ERROR: No matching database found for selection: $DB_FILTER" | tee -a "$LOG_FILE"
  exit 1
fi

print_summary

echo
echo "Log file: $LOG_FILE"

if [[ "$FAILED_CNT" -gt 0 ]]; then
  exit 2
fi

