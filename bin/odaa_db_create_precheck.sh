#!/usr/bin/env bash
source "$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)/lib/odaa_common.sh"

RUN_SIDE=""; DB_FILTER="ALL"; TEST_MODE="false"
usage(){ cat <<USAGE
Usage: $(basename "$0") -p|-s [-a|-d db1,db2] [-i ini_file] [-t]
  -p Primary values from INI
  -s Standby values from INI
  -a All databases
  -d Database name or comma-separated list
  -i INI file path
  -t Testing mode: print dbaascli commands only
USAGE
exit 1; }
while getopts ":psad:i:th" opt; do case "$opt" in p) RUN_SIDE="PRIMARY";; s) RUN_SIDE="STANDBY";; a) DB_FILTER="ALL";; d) DB_FILTER="$OPTARG";; i) INI_FILE="$OPTARG";; t) TEST_MODE="true";; h|*) usage;; esac; done
[[ -n "$RUN_SIDE" ]] || usage
start_logging "odaa_db_create_precheck_${RUN_SIDE}"
print_banner "DBaaSCLI database create precheck" "$RUN_SIDE TEST=$TEST_MODE" "$DB_FILTER"
require_dbaascli; require_readable "$INI_FILE"; chmod 600 "$INI_FILE" 2>/dev/null || true
summ "DBaaSCLI Version:"; dbaascli_version | tee -a "$SUMMARY_FILE" || true
PASS=0; FAIL=0; SKIP=0
while IFS='|' read -r dbName dbUniqueName dbSID dbCharset dbNCharset pdatafileDestination pfraDestination pNodeList port syspass tdepass primaryScanIPAddresses primaryScanPort pServiceName standbyScanIPAddresses standbyScanPort sServiceName standbyDBUniqueName sdatafileDestination sfraDestination sNodeList flagSkip dbBlockSizeInKB enableCDB dbHome rest; do
  dbName="$(echo "${dbName:-}"|xargs)"; [[ -n "$dbName" ]] || continue; is_selected_db "$dbName" "$DB_FILTER" || continue
  [[ "$(normalize_flag "$flagSkip")" == "Y" ]] && { summ "SKIP $dbName flagSkip=Y"; ((SKIP++)); continue; }
  if [[ "$RUN_SIDE" == "PRIMARY" ]]; then T_DB_NAME="$dbName"; T_UNQ="$dbUniqueName"; T_SID="$dbSID"; T_DATA="$pdatafileDestination"; T_FRA="$pfraDestination"; T_NODES="$pNodeList"; T_SCAN="$primaryScanIPAddresses"; T_PORT="$primaryScanPort"; else T_DB_NAME="$dbName"; T_UNQ="$standbyDBUniqueName"; T_SID="$standbyDBUniqueName"; T_DATA="$sdatafileDestination"; T_FRA="$sfraDestination"; T_NODES="$sNodeList"; T_SCAN="$standbyScanIPAddresses"; T_PORT="$standbyScanPort"; fi
  T_HOME="${dbHome:-$DEFAULT_ORACLE_HOME}"
  summ "PRECHECK START $dbName ($RUN_SIDE unique=$T_UNQ)"
  CMD=(sudo "$DBAASCLI" database create --dbName "$T_DB_NAME" --oracleHome "$T_HOME" --dbUniqueName "$T_UNQ" --dbSID "$T_SID" --dbCharset "$dbCharset" --dbNCharset "$dbNCharset" --datafileDestination "$T_DATA" --recoveryAreaDestination "$T_FRA" --nodelist "$T_NODES" --listenerPort "${port:-1521}" --tdeConfigMethod "$TDE_CONFIG_METHOD" --fraSizeInMB "$FRA_SIZE_MB" --dbBlockSizeInKB "${dbBlockSizeInKB:-16}" --enableCDB "${enableCDB:-true}" --executePrereqs yes --waitForCompletion "$WAIT_FOR_COMPLETION")
  if [[ "$TEST_MODE" == "true" ]]; then printf 'TEST MODE CMD: %q ' "${CMD[@]}" | tee -a "$SUMMARY_FILE"; echo | tee -a "$SUMMARY_FILE"; ((PASS++)); continue; fi
  if printf '%s\n%s\n%s\n%s\n' "$syspass" "$syspass" "${tdepass:-$syspass}" "${tdepass:-$syspass}" | "${CMD[@]}"; then summ "PASS $dbName precheck"; ((PASS++)); else summ "FAIL $dbName precheck"; ((FAIL++)); fi
done < <(ini_rows)
summ "Completed: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; [[ $FAIL -eq 0 ]]
