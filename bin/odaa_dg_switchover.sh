#!/usr/bin/env bash
source "$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)/lib/odaa_common.sh"
ACTION=""; RUN_SIDE=""; DB_FILTER=""; TEST_MODE="false"
usage(){ cat <<USAGE
Usage:
  $(basename "$0") -p|-s --status --all|-d db1,db2 [-t]
  $(basename "$0") -p|-s --switchover|-d db [-t]
  $(basename "$0") -p|-s --failover|-d db [-t]
  $(basename "$0") -p|-s --snapshot|-d db [-t]
  $(basename "$0") -p|-s --convert-standby|-d db [-t]
  $(basename "$0") -p|-s --fix-broker|-d db [-t]
USAGE
exit 1; }
while [[ $# -gt 0 ]]; do case "$1" in -p|--primary) RUN_SIDE="PRIMARY"; shift;; -s|--standby) RUN_SIDE="STANDBY"; shift;; --status) ACTION="STATUS"; shift;; --switchover) ACTION="SWITCHOVER"; shift;; --failover) ACTION="FAILOVER"; shift;; --snapshot) ACTION="SNAPSHOT"; shift;; --convert-standby) ACTION="CONVERT_STANDBY"; shift;; --fix-broker) ACTION="FIX_BROKER"; shift;; --all|-a) DB_FILTER="ALL"; shift;; -d|--database) DB_FILTER="$2"; shift 2;; -i) INI_FILE="$2"; shift 2;; -t|--test) TEST_MODE="true"; shift;; -h|--help) usage;; *) usage;; esac; done
[[ -n "$RUN_SIDE" && -n "$ACTION" && -n "$DB_FILTER" ]] || usage
[[ "$ACTION" != "STATUS" && "$DB_FILTER" == "ALL" ]] && die "--all is allowed only with --status"
start_logging "dg_control_${RUN_SIDE}_${ACTION}"; print_banner "Data Guard Control - Status/Switchover/Failover/Snapshot/Fix Broker" "$ACTION $RUN_SIDE TEST=$TEST_MODE" "$DB_FILTER"
require_dbaascli; require_readable "$INI_FILE"
PASS=0; FAIL=0; SKIP=0
run_dg(){ local db="$1" stby="$2" svc="$3"; local cmd=(); case "$ACTION" in STATUS) cmd=(sudo "$DBAASCLI" dataguard status --dbname "$db");; SWITCHOVER) cmd=(sudo "$DBAASCLI" dataguard switchover --dbname "$db" --targetStandbyDBUniqueName "$stby" --waitForCompletion "$WAIT_FOR_COMPLETION");; FAILOVER) cmd=(sudo "$DBAASCLI" dataguard failover --dbname "$db" --targetStandbyDBUniqueName "$stby" --waitForCompletion "$WAIT_FOR_COMPLETION");; SNAPSHOT) cmd=(sudo "$DBAASCLI" dataguard convertToSnapshotStandby --dbname "$db" --standbyDBUniqueName "$stby" --waitForCompletion "$WAIT_FOR_COMPLETION");; CONVERT_STANDBY) cmd=(sudo "$DBAASCLI" dataguard convertToPhysicalStandby --dbname "$db" --standbyDBUniqueName "$stby" --waitForCompletion "$WAIT_FOR_COMPLETION");; FIX_BROKER) cmd=(dgmgrl -silent / "edit database '$stby' set property DGConnectIdentifier='$svc';" "show configuration;" );; esac; if [[ "$TEST_MODE" == "true" ]]; then printf 'TEST CMD: %q ' "${cmd[@]}"; echo; return 0; else "${cmd[@]}"; fi; }
while IFS='|' read -r dbName dbUniqueName dbSID dbCharset dbNCharset pdatafileDestination pfraDestination pNodeList port syspass tdepass primaryScanIPAddresses primaryScanPort pServiceName standbyScanIPAddresses standbyScanPort sServiceName standbyDBUniqueName sdatafileDestination sfraDestination sNodeList flagSkip dbBlockSizeInKB enableCDB dbHome rest; do
 dbName="$(echo "${dbName:-}"|xargs)"; [[ -n "$dbName" ]] || continue; is_selected_db "$dbName" "$DB_FILTER" || continue
 [[ "$(normalize_flag "$flagSkip")" == "Y" ]] && { summ "SKIP $dbName flagSkip=Y"; ((SKIP++)); continue; }
 summ "START $ACTION $dbName target=$standbyDBUniqueName"
 if run_dg "$dbName" "$standbyDBUniqueName" "$sServiceName"; then summ "PASS $ACTION $dbName"; ((PASS++)); else summ "FAIL $ACTION $dbName"; ((FAIL++)); fi
done < <(ini_rows)
summ "Completed: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; [[ $FAIL -eq 0 ]]
